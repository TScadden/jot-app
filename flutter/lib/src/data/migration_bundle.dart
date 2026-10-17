import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';

/// TAKEOVER Phase 4 — the Lab → production migration bridge (Ivy's
/// Phase 0 inventory: `team/hidden_files/takeover/P0-local-state.md`).
///
/// The Lab and the production app are different Android packages, so
/// their sandboxes are mutually unreadable: the ONLY way device-local
/// state crosses is a file the user carries from the Lab's share
/// sheet into the production app's file picker. This file is that
/// bridge. One JSON envelope:
///
/// ```json
/// {"bundle": "tabs-lab-migration", "version": 1,
///  "exportedAt": <epoch ms>, "ownerEmail": "<normalized email>",
///  "stores": {"<secure-storage key>": "<raw stored string>", …}}
/// ```
///
/// VERBATIM RULE (Ivy §4/§5, load-bearing): every value in `stores`
/// is the RAW secure-storage string copied byte for byte — never
/// decoded and re-encoded. The account-bound loaders clean, dedupe,
/// cap, and DROP unknown keys on their next persist, so a
/// decode/re-encode round trip through this layer could silently
/// rewrite the very blobs it is meant to preserve (coach facts,
/// the accumulated health-history union). Bundle metadata lives in
/// the envelope, never inside a blob.
///
/// IMPORT ORDER (Ivy §7): the canonical key order below is both the
/// export order and the import write order — coach memory first,
/// then the history store, then the Settings keys (the first-run
/// reminder reconcile reads the check-in toggle + appointment date,
/// so settings land before it runs), then the small stores.
///
/// OWNER TRAP (Ivy §4): `CoachMemoryStore.load(email)` WIPES a blob
/// whose recorded owner differs from the session email. Import
/// therefore (a) refuses a bundle whose envelope `ownerEmail` does
/// not match the signed-in account — writing nothing — and (b)
/// writes the raw blobs directly to secure storage, so no coach /
/// history load for the new account can run against a half-imported
/// state. Callers must run import AFTER production sign-in and
/// surface it before the user opens Coach/History (the Settings
/// action satisfies both; see settings_screen.dart).
///
/// DELIBERATELY EXCLUDED (Ivy §7): auth tokens / session email
/// (credentials never travel in a file — one re-login), the four
/// render-seed caches, the Health Connect grant records, onboarding
/// keys, `settings_last_sync_time` (bookkeeping), the tips cache,
/// and the count-up gate — all server-synced or re-derived on first
/// run.
class MigrationException implements Exception {
  /// Stable machine code for logs/tests (`OWNER_MISMATCH`, …).
  final String code;

  /// Plain user-facing explanation. Safe to show verbatim.
  final String message;

  const MigrationException(this.code, this.message);

  @override
  String toString() => 'MigrationException($code): $message';
}

/// Failure from the migration file bridges (picker / share sheet).
/// [code] is the Kotlin side's stable error code, mirroring the
/// CsvPickException / KnowledgePickException pattern.
class MigrationFileException implements Exception {
  final String code;
  final String? message;

  const MigrationFileException(this.code, [this.message]);

  @override
  String toString() => 'MigrationFileException($code)';
}

/// What a successful import wrote, for the caller's confirmation UI.
class MigrationImportResult {
  /// Secure-storage keys written, in canonical import order.
  final List<String> importedKeys;

  /// The bundle's normalized owner email (== the signed-in account).
  final String ownerEmail;

  /// The bundle's `exportedAt` (epoch ms), 0 when absent.
  final int exportedAt;

  const MigrationImportResult({
    required this.importedKeys,
    required this.ownerEmail,
    required this.exportedAt,
  });
}

/// Builds and consumes migration bundles against an injectable
/// [SecureStore] (the app's flutter_secure_storage seam — see
/// health_connect_service.dart). Tests drive it with in-memory maps;
/// production uses the default [FlutterSecureStore].
class MigrationBundleService {
  static const String bundleId = 'tabs-lab-migration';
  static const int bundleVersion = 1;
  static const String fileName = 'tabs-lab-migration.json';

  // Secure-storage keys (Ivy P0 §1/§4/§5). The literals are the
  // contract; they intentionally duplicate the owning stores'
  // `storageKey` constants so this bridge keeps working for keys
  // whose store does not exist in this build yet (the R70 history
  // store) or whose keys live in a feature file (food / tile order).
  static const String coachMemoryKey = 'coach_memory_v1';
  static const String healthHistoryKey = 'health_history_store_v1';
  static const String foodHistoryKey = 'food_checker_history';
  static const String toolsTileOrderKey = 'tools_tile_order_v1';
  static const String knowledgeExtractedKey = 'knowledge_extracted_v1';
  static const String todayPlanKey = 'today_plan_state_v1';

  /// The 13 local-only Settings keys (Ivy P0 §1.5/§7 item 3) —
  /// every SettingsStore / R66 report key except the
  /// `settings_last_sync_time` bookkeeping stamp. The five
  /// `progress_report_*` keys are read/written RAW here: the R66
  /// store accessors do not exist in this base, and raw access is
  /// exactly what keeps them portable when they land.
  static const List<String> settingsKeys = [
    'settings_show_nav_labels',
    'settings_theme_mode',
    'settings_user_context_hidden',
    'settings_checkin_reminder_enabled',
    'settings_google_calendar_connected',
    'settings_google_calendar_email',
    'settings_google_account_connected',
    'settings_google_account_email',
    'progress_report_last_type',
    'progress_report_last_range_30d',
    'progress_report_last_export_ms',
    'progress_report_appointment_date',
    'progress_report_appointment_type',
  ];

  /// Canonical bundle order = import write order (Ivy §7):
  /// coach memory, history (read-if-present), the Settings keys,
  /// food history, tile order, extracted knowledge (optional), and
  /// today's plan state (same-day exports only — enforced on the
  /// export side; an imported stale blob self-wipes on first load,
  /// exactly like a Lab blob from another day).
  static const List<String> importOrder = [
    coachMemoryKey,
    healthHistoryKey,
    ...settingsKeys,
    foodHistoryKey,
    toolsTileOrderKey,
    knowledgeExtractedKey,
    todayPlanKey,
  ];

  final SecureStore _store;
  final DateTime Function() _now;

  MigrationBundleService({SecureStore? store, DateTime Function()? now})
      : _store = store ?? const FlutterSecureStore(),
        _now = now ?? DateTime.now;

  /// `yyyy-MM-dd` device-local — the TodayPlanStore blob's `date`
  /// format (same construction as `dateStrOf` in today_summary.dart).
  static String dateStrOf(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Reads every bundle member VERBATIM from secure storage and
  /// returns the envelope as a JSON string, ready for the share
  /// sheet. Keys with no stored value are omitted. The Today Plan
  /// blob is included ONLY when its recorded `date` is today
  /// (device-local) — it is single-day state and self-wipes on any
  /// other day (Ivy §1.7).
  ///
  /// Throws [MigrationException] (`NO_ACCOUNT`) when [ownerEmail]
  /// is missing — a bundle with no owner could never pass the
  /// import-side account check — and (`NOTHING_TO_EXPORT`) when no
  /// bundle member exists on this device.
  Future<String> buildExportJson({required String? ownerEmail}) async {
    final owner = CoachMemoryStore.normalizeEmail(ownerEmail);
    if (owner == null) {
      throw const MigrationException(
        'NO_ACCOUNT',
        'You need to be signed in to export your data. Sign in, then '
        'try exporting again.',
      );
    }
    final now = _now();
    final today = dateStrOf(now);
    final stores = <String, String>{};
    for (final key in importOrder) {
      final raw = await _store.read(key);
      if (raw == null) continue;
      if (key == todayPlanKey && !_isSameDayPlan(raw, today)) continue;
      stores[key] = raw;
    }
    if (stores.isEmpty) {
      throw const MigrationException(
        'NOTHING_TO_EXPORT',
        'There is no on-device data to export yet. Your coach '
        'memory, settings, and history will appear here once you '
        'have used the Lab.',
      );
    }
    return jsonEncode({
      'bundle': bundleId,
      'version': bundleVersion,
      'exportedAt': now.millisecondsSinceEpoch,
      'ownerEmail': owner,
      'stores': stores,
    });
  }

  bool _isSameDayPlan(String raw, String today) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded['date'] == today;
    } catch (_) {
      // An unreadable blob cannot prove it is today's — leave it
      // behind rather than carry state its own loader would wipe.
      return false;
    }
  }

  /// Validates [jsonText] end-to-end, then writes each present
  /// store's RAW string verbatim under its original key, in
  /// canonical import order.
  ///
  /// Validation is ALL-OR-NOTHING and completes before the first
  /// write: a malformed file, an unsupported version, a missing
  /// sign-in, or an owner mismatch writes NOTHING. The owner check
  /// compares normalized emails (the CoachMemoryStore rule) — the
  /// bundle's account must be the signed-in account, because the
  /// account-bound blobs inside it are stamped with that owner and
  /// any other account's first load would wipe them (Ivy §4 trap).
  ///
  /// Unknown keys in `stores` are ignored (forward compatibility);
  /// known keys with non-string values fail validation.
  Future<MigrationImportResult> importBundleJson(
    String jsonText, {
    required String? currentEmail,
  }) async {
    final Map<String, dynamic> envelope;
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('envelope is not an object');
      }
      envelope = decoded;
    } catch (_) {
      throw const MigrationException(
        'INVALID_FILE',
        'That file could not be read as a Tabs data export. Pick '
        'the file the Tabs Lab created when you exported, and try '
        'again. Nothing was imported.',
      );
    }
    if (envelope['bundle'] != bundleId) {
      throw const MigrationException(
        'INVALID_FILE',
        'That file is not a Tabs data export. Pick the file the '
        'Tabs Lab created when you exported, and try again. '
        'Nothing was imported.',
      );
    }
    final version = envelope['version'];
    if (version is! num || version.toInt() != bundleVersion) {
      throw const MigrationException(
        'UNSUPPORTED_VERSION',
        'This export was made by a newer version of Tabs and cannot '
        'be imported here. Update the app, then try again. Nothing '
        'was imported.',
      );
    }
    final bundleOwner =
        CoachMemoryStore.normalizeEmail(envelope['ownerEmail']?.toString());
    if (bundleOwner == null) {
      throw const MigrationException(
        'INVALID_FILE',
        'That export does not say which account it belongs to, so '
        'it cannot be imported safely. Export it again from the '
        'Tabs Lab and try again. Nothing was imported.',
      );
    }
    final current = CoachMemoryStore.normalizeEmail(currentEmail);
    if (current == null) {
      throw const MigrationException(
        'NOT_SIGNED_IN',
        'Sign in to your account first, then import. The import '
        'has to land in the same account that exported it. Nothing '
        'was imported.',
      );
    }
    if (bundleOwner != current) {
      throw MigrationException(
        'OWNER_MISMATCH',
        'This file was exported from the account $bundleOwner, but '
        'you are signed in as $current. Your coach memory and '
        'history belong to the account that created them, so they '
        'can only be imported while signed in as $bundleOwner. '
        'Nothing was imported.',
      );
    }
    final rawStores = envelope['stores'];
    if (rawStores is! Map) {
      throw const MigrationException(
        'INVALID_FILE',
        'That export is missing its data section. Export it again '
        'from the Tabs Lab and try again. Nothing was imported.',
      );
    }
    // Collect + type-check every known entry BEFORE any write.
    final toWrite = <String, String>{};
    for (final key in importOrder) {
      if (!rawStores.containsKey(key)) continue;
      final value = rawStores[key];
      if (value is! String) {
        throw const MigrationException(
          'INVALID_FILE',
          'That export has a damaged entry and cannot be imported '
          'safely. Export it again from the Tabs Lab and try again. '
          'Nothing was imported.',
        );
      }
      toWrite[key] = value;
    }
    if (toWrite.isEmpty) {
      throw const MigrationException(
        'NOTHING_TO_IMPORT',
        'That export does not contain any data this app can use. '
        'Nothing was imported.',
      );
    }
    // Writes: raw strings, verbatim, canonical order. Direct secure-
    // storage writes only — no store load runs in this path, so the
    // coach blob cannot be wiped by its own owner check before the
    // account's first real load reads it back intact.
    final written = <String>[];
    try {
      for (final entry in toWrite.entries) {
        await _store.write(entry.key, entry.value);
        written.add(entry.key);
      }
    } catch (_) {
      throw MigrationException(
        'WRITE_FAILED',
        'Your data could not be saved completely on this device '
        '(${written.length} of ${toWrite.length} items were '
        'written). Free up space if needed, then import the file '
        'again — importing again is safe.',
      );
    }
    final exportedAtRaw = envelope['exportedAt'];
    return MigrationImportResult(
      importedKeys: written,
      ownerEmail: bundleOwner,
      exportedAt: exportedAtRaw is num ? exportedAtRaw.toInt() : 0,
    );
  }
}

/// Picks ONE migration file through the Android Storage Access
/// Framework (the Flutter host's MainActivity registers a dedicated
/// GetContent launcher on the existing file_picker channel) and
/// returns its text. Returns null when the user cancels. Throws
/// [MigrationFileException] on too-large / unreadable / unavailable
/// — never silent (team lesson).
class MigrationFilePicker {
  static const String channelName =
      'com.notel.notel.playground.flutter/file_picker';

  final MethodChannel _channel;

  MigrationFilePicker({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  Future<String?> pickMigrationText() async {
    try {
      return await _channel.invokeMethod<String>('pickMigrationText');
    } on PlatformException catch (e) {
      throw MigrationFileException(e.code, e.message);
    } on MissingPluginException {
      throw const MigrationFileException(
          'UNAVAILABLE', "Couldn't open the file picker.");
    }
  }
}

/// Hands the export file to the platform share sheet (the host
/// writes it to the app cache dir and opens an ACTION_SEND chooser
/// with a FileProvider URI — the Round 48 CSV export pattern). The
/// file is deliberately NOT copied to Downloads: it carries health
/// data, and the share sheet is the delivery, not a second copy.
class MigrationShareService {
  static const String channelName =
      'com.notel.notel.playground.flutter/file_picker';

  final MethodChannel _channel;

  MigrationShareService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// True only when the share sheet was launched.
  Future<bool> shareMigrationFile({
    required String fileName,
    required String content,
  }) async {
    try {
      return await _channel.invokeMethod<bool>(
            'shareMigrationFile',
            {'fileName': fileName, 'content': content},
          ) ??
          false;
    } on PlatformException catch (e) {
      throw MigrationFileException(e.code, e.message);
    } on MissingPluginException {
      throw const MigrationFileException(
          'UNAVAILABLE', "Couldn't open the share sheet.");
    }
  }
}
