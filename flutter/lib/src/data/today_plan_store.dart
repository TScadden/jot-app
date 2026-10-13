import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/today_summary.dart';

/// Round 35 — device-local state for the Home Today Summary plan,
/// mirroring where native keeps the same facts:
///
/// - Completed reminders: native `NotelPreferences.getCompletedReminders(
///   dateStr)` — a DataStore set of reminder ids, keyed BY DATE,
///   never synced. The Flutter reminders blob carries the same native
///   ids, so the same keying works here.
/// - Medication dose actions: native `ScheduledDoseOccurrence` rows,
///   keyed `med_<identifier>_<date>_<slot>`, also device-local
///   (`syncState = "SAVED_LOCALLY"`, no server endpoint exists).
///   The TAKEN action additionally writes a synced log entry (see
///   `today_summary.dart`), but SKIPPED/SNOOZED/PENDING-undo exist
///   only in this store — exactly like native, where the occurrence
///   row is the only record of a skip.
///
/// Storage: one JSON blob in flutter_secure_storage (same encrypted
/// at-rest store as the session), shaped
/// `{ownerEmail, date, completedReminderIds: [...], medActions:
/// {"medKey|slot": "TAKEN"|"SKIPPED"|"SNOOZED"|"PENDING"}}`.
///
/// Account binding (Round 19c pattern, parity with [HomeDataCache]):
/// the blob is owned by one account. A load under a different session
/// email drops the blob instead of leaking the previous account's
/// plan state into the new account's summary.
///
/// Date binding: state is meaningful only for its own device-local
/// day. A blob from another day loads as empty (native keys by date
/// the same way) — yesterday's completions never bleed into today.
///
/// Never throws: every storage failure degrades to "no local state",
/// which is the honest native first-run state too.
class TodayPlanStore {
  static const String storageKey = 'today_plan_state_v1';

  static final TodayPlanStore instance = TodayPlanStore._internal();
  TodayPlanStore._internal();

  /// Standalone instance for tests (no shared singleton state).
  factory TodayPlanStore.testInstance() = TodayPlanStore._internal;

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  @visibleForTesting
  void debugSetStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) {
    _read = read;
    _write = write;
    if (delete != null) _delete = delete;
  }

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  static String medActionKey(String medKey, String slot) => '$medKey|$slot';

  /// Loads today's local plan state for [email]. Returns an empty
  /// state when the blob is missing, corrupt, owned by another
  /// account, or dated another day (the latter two also wipe the
  /// blob so stale state never resurfaces).
  Future<TodayPlanLocalState> load({
    required String? email,
    required String todayStr,
  }) async {
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return const TodayPlanLocalState();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const TodayPlanLocalState();
      }
      final owner = decoded['ownerEmail'];
      final blobOwner = owner is String ? _normalizeEmail(owner) : null;
      final expected = _normalizeEmail(email);
      if (expected != null && blobOwner != expected) {
        await _wipe();
        return const TodayPlanLocalState();
      }
      if (decoded['date'] != todayStr) {
        // Another day's state: native would find an empty set for
        // today too. Drop it so the blob stays single-day.
        await _wipe();
        return const TodayPlanLocalState();
      }
      final completed = <int>{};
      final rawIds = decoded['completedReminderIds'];
      if (rawIds is List) {
        for (final v in rawIds) {
          final n = v is num ? v.toInt() : int.tryParse('$v');
          if (n != null) completed.add(n);
        }
      }
      final actions = <String, DoseStatus>{};
      final rawActions = decoded['medActions'];
      if (rawActions is Map) {
        for (final e in rawActions.entries) {
          final status = doseStatusFromName('${e.value}');
          if (e.key is String && status != null) {
            actions[e.key as String] = status;
          }
        }
      }
      return TodayPlanLocalState(
        completedReminderIds: completed,
        medActions: actions,
      );
    } catch (_) {
      return const TodayPlanLocalState();
    }
  }

  Future<void> setReminderCompleted({
    required String? email,
    required String todayStr,
    required int reminderId,
    required bool completed,
  }) async {
    final state = await load(email: email, todayStr: todayStr);
    final ids = {...state.completedReminderIds};
    if (completed) {
      ids.add(reminderId);
    } else {
      ids.remove(reminderId);
    }
    await _save(email, todayStr,
        TodayPlanLocalState(completedReminderIds: ids, medActions: state.medActions));
  }

  Future<void> setMedAction({
    required String? email,
    required String todayStr,
    required String medKey,
    required String slot,
    required DoseStatus status,
  }) async {
    final state = await load(email: email, todayStr: todayStr);
    final actions = {...state.medActions};
    actions[medActionKey(medKey, slot)] = status;
    await _save(
        email,
        todayStr,
        TodayPlanLocalState(
            completedReminderIds: state.completedReminderIds,
            medActions: actions));
  }

  Future<void> _save(
      String? email, String todayStr, TodayPlanLocalState state) async {
    try {
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': _normalizeEmail(email),
          'date': todayStr,
          'completedReminderIds': state.completedReminderIds.toList(),
          'medActions': {
            for (final e in state.medActions.entries)
              e.key: doseStatusName(e.value),
          },
        }),
      );
    } catch (_) {
      // Local state is best-effort: a storage failure must never
      // break the summary (native writes are likewise fire-and-forget
      // from the UI's perspective).
    }
  }

  Future<void> _wipe() async {
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Wipes the blob (logout / account-deletion hook). Never throws.
  Future<void> clear() => _wipe();
}

/// Immutable snapshot of the device-local plan state for one day.
class TodayPlanLocalState {
  final Set<int> completedReminderIds;
  final Map<String, DoseStatus> medActions;

  const TodayPlanLocalState({
    this.completedReminderIds = const {},
    this.medActions = const {},
  });
}
