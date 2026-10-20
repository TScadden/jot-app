import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Round 29 — on-device-only Settings values.
///
/// Native audit (SettingsScreen.kt + SettingsViewModel.kt +
/// NotelPreferences.kt): a handful of settings live ONLY in the native
/// DataStore and are NEVER sent to the server (they are absent from
/// `SyncProfileRequest`, JotApi.kt:219-261, and from
/// `SyncManager.pushProfileData`):
/// - `show_nav_labels` (bool, default true) — NotelPreferences.kt:162
/// - `theme_mode` (string "DARK"|"LIGHT"|"SYSTEM", default DARK) — :163
/// - `user_context_hidden` (bool, default true) — :127 key, :619 default
/// - `tabs_lab_checkin_reminder_enabled` (bool, default true) — :111.
///   Native arms/cancels a 4 AM alarm when this flips; Round 30 wires
///   the Flutter equivalent (ReminderSync in notification_service.dart
///   schedules/cancels the daily 4 AM notification with the toggle).
/// - `google_calendar_connected` / `google_calendar_email` and
///   `google_account_connected` / `google_account_email` — native
///   keeps all four in DataStore only (NotelPreferences.kt:155-156,
///   :329-336 and the google-account equivalents); never synced.
/// - `last_sync_time` (epoch ms, default 0) — :128. Native updates it
///   on every successful profile push/pull; the Flutter Settings
///   "Sync Now" stamps it after a successful pull.
///
/// This store mirrors those keys with the app's existing local-storage
/// approach — flutter_secure_storage (Android Keystore-backed
/// EncryptedSharedPreferences), the same store the session and the
/// account-bound caches use. Injectable read/write/delete for tests,
/// following the caches' pattern.
class SettingsStore {
  static const showNavLabelsKey = 'settings_show_nav_labels';
  static const themeModeKey = 'settings_theme_mode';
  static const userContextHiddenKey = 'settings_user_context_hidden';
  static const checkInReminderKey = 'settings_checkin_reminder_enabled';
  static const lastSyncTimeKey = 'settings_last_sync_time';
  static const googleCalendarConnectedKey =
      'settings_google_calendar_connected';
  static const googleCalendarEmailKey = 'settings_google_calendar_email';
  static const googleAccountConnectedKey =
      'settings_google_account_connected';
  static const googleAccountEmailKey = 'settings_google_account_email';
  // Round 66 — Progress Reports prefs (native NotelPreferences:
  // LAST_REPORT_TYPE / LAST_REPORT_RANGE_30D / LAST_REPORT_EXPORT_TIME
  // / APPOINTMENT_DATE / APPOINTMENT_REPORT_TYPE, DataStore-only).
  static const reportLastTypeKey = 'progress_report_last_type';
  static const reportLastRange30dKey = 'progress_report_last_range_30d';
  static const reportLastExportKey = 'progress_report_last_export_ms';
  static const reportAppointmentDateKey =
      'progress_report_appointment_date';
  static const reportAppointmentTypeKey =
      'progress_report_appointment_type';
  // Counter-mutation durability (Oct 2026) — locally persisted
  // deleted-event-counter tombstones (native parity:
  // `deletedEventCounterIds` in NotelPreferences, filtered in
  // SyncManager's pull merge). Device-only, like every key in this
  // store: the ids are the user's own counter ids, are never sent
  // to the server, and are wiped by [clear] on explicit logout /
  // account deletion with the rest of the account-bound state —
  // and, since the correction round (Juno C2), by
  // [clearDeletedCounterIds] on a forced session expiry, which
  // previously left them behind.
  static const deletedCounterIdsKey = 'settings_deleted_counter_ids';
  static const deletedCounterOwnerKey =
      'settings_deleted_counter_owner';

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  SettingsStore();

  SettingsStore._(this._read, this._write, this._delete);

  @visibleForTesting
  factory SettingsStore.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required Future<void> Function(String key) delete,
  }) =>
      SettingsStore._(read, write, delete);

  Future<bool> _readBool(String key, bool fallback) async {
    try {
      final v = await _read(key);
      if (v == 'true') return true;
      if (v == 'false') return false;
    } catch (_) {}
    return fallback;
  }

  Future<void> _writeBool(String key, bool value) =>
      _write(key, value ? 'true' : 'false');

  /// Native default true (NotelPreferences.kt:269).
  Future<bool> getShowNavLabels() => _readBool(showNavLabelsKey, true);
  Future<void> setShowNavLabels(bool v) => _writeBool(showNavLabelsKey, v);

  /// Native default "DARK" (NotelPreferences.kt:163 comment).
  Future<String> getThemeMode() async {
    try {
      final v = await _read(themeModeKey);
      if (v == 'LIGHT' || v == 'DARK' || v == 'SYSTEM') return v!;
    } catch (_) {}
    return 'DARK';
  }

  Future<void> setThemeMode(String v) => _write(themeModeKey, v);

  /// Native default true (NotelPreferences.kt:619, `?: true`).
  Future<bool> getUserContextHidden() =>
      _readBool(userContextHiddenKey, true);
  Future<void> setUserContextHidden(bool v) =>
      _writeBool(userContextHiddenKey, v);

  /// Native default true (NotelPreferences.kt:424).
  Future<bool> getCheckInReminderEnabled() =>
      _readBool(checkInReminderKey, true);
  Future<void> setCheckInReminderEnabled(bool v) =>
      _writeBool(checkInReminderKey, v);

  Future<int> getLastSyncTimeMs() async {
    try {
      return int.tryParse(await _read(lastSyncTimeKey) ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> setLastSyncTimeMs(int ms) =>
      _write(lastSyncTimeKey, '$ms');

  /// Native default false (NotelPreferences.kt:329).
  Future<bool> getGoogleCalendarConnected() =>
      _readBool(googleCalendarConnectedKey, false);
  Future<void> setGoogleCalendarConnected(bool v) =>
      _writeBool(googleCalendarConnectedKey, v);

  Future<String> getGoogleCalendarEmail() async {
    try {
      return await _read(googleCalendarEmailKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> setGoogleCalendarEmail(String v) =>
      _write(googleCalendarEmailKey, v);

  /// Native default false.
  Future<bool> getGoogleAccountConnected() =>
      _readBool(googleAccountConnectedKey, false);
  Future<void> setGoogleAccountConnected(bool v) =>
      _writeBool(googleAccountConnectedKey, v);

  Future<String> getGoogleAccountEmail() async {
    try {
      return await _read(googleAccountEmailKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> setGoogleAccountEmail(String v) =>
      _write(googleAccountEmailKey, v);

  // ── Round 66 — Progress Reports prefs ───────────────────────────

  /// Native default "health" (NotelPreferences.lastReportType).
  Future<String> getReportLastType() async {
    try {
      final v = await _read(reportLastTypeKey);
      if (v == 'health' || v == 'training' || v == 'custom') return v!;
    } catch (_) {}
    return 'health';
  }

  Future<void> setReportLastType(String v) => _write(reportLastTypeKey, v);

  /// Native default true (NotelPreferences.lastReportRange30d).
  Future<bool> getReportLastRange30d() =>
      _readBool(reportLastRange30dKey, true);
  Future<void> setReportLastRange30d(bool v) =>
      _writeBool(reportLastRange30dKey, v);

  Future<int> getReportLastExportMs() async {
    try {
      return int.tryParse(await _read(reportLastExportKey) ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> setReportLastExportMs(int ms) =>
      _write(reportLastExportKey, '$ms');

  /// Saved appointment date as ISO `yyyy-MM-dd`, or null when none.
  Future<String?> getReportAppointmentDate() async {
    try {
      final v = await _read(reportAppointmentDateKey);
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<void> setReportAppointmentDate(String? iso) =>
      iso == null ? _delete(reportAppointmentDateKey) : _write(reportAppointmentDateKey, iso);

  /// Native default "health" (NotelPreferences.appointmentReportType).
  Future<String> getReportAppointmentType() async {
    try {
      final v = await _read(reportAppointmentTypeKey);
      if (v == 'health' || v == 'training' || v == 'custom') return v!;
    } catch (_) {}
    return 'health';
  }

  Future<void> setReportAppointmentType(String v) =>
      _write(reportAppointmentTypeKey, v);

  // ── Counter delete tombstones (Oct 2026) ──────────────────────

  static String? _normalizeOwner(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  /// The stored tombstone ids with NO owner logic applied.
  /// Never throws.
  Future<Set<String>> _readRawDeletedCounterIds() async {
    try {
      final raw = await _read(deletedCounterIdsKey);
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const {};
      return decoded.map((e) => '$e').where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return const {};
    }
  }

  /// The locally persisted deleted-counter ids owned by
  /// [ownerEmail] (the session account email; null when unknown).
  ///
  /// Account binding (following the HomeDataCache owner pattern,
  /// adapted to this data's risk): a POSITIVE owner mismatch — a
  /// stored owner that is a DIFFERENT account — drops the set
  /// (ids deleted, the current account bound in its place) and
  /// returns empty, so one account's tombstones can never hide
  /// another account's counters. A set with NO recorded owner is
  /// ADOPTED instead (the current owner is stamped, the ids kept):
  /// it can only have been written by an email-less surface of
  /// this same install, counter ids are per-account timestamps,
  /// and the hard account-separation guarantee is [clear], which
  /// wipes these keys on explicit logout / account deletion (a
  /// forced session expiry wipes just these two keys via
  /// [clearDeletedCounterIds]).
  ///
  /// Correction round (Juno C2): when [ownerEmail] is UNKNOWN
  /// (null — an email-less surface like Research → Settings) and
  /// the stored set HAS an owner, the read returns EMPTY: the
  /// reader cannot prove the set is theirs, and the previous
  /// return-as-is behavior let a previous account's bound set
  /// filter a new account's counters through that surface. An
  /// UNOWNED set (no stored owner) is still returned as-is to a
  /// null-owner reader — it can only have been written by an
  /// email-less surface of this same install. Nothing is dropped
  /// or re-bound by a null-owner read. Never throws.
  Future<Set<String>> getDeletedCounterIds({String? ownerEmail}) async {
    try {
      final owner = _normalizeOwner(ownerEmail);
      final ids = await _readRawDeletedCounterIds();
      if (ids.isEmpty) return const {};
      final storedOwner =
          _normalizeOwner(await _read(deletedCounterOwnerKey));
      if (owner == null) {
        // Bound to SOME account, reader unknown: not provably
        // theirs — read empty (Juno C2). Unowned set: returned
        // as-is (email-less surfaces of this same install).
        return storedOwner != null ? const {} : ids;
      }
      if (storedOwner != null && storedOwner != owner) {
        // Another account's set: drop it and bind the current
        // account (HomeDataCache clearIfOwnerMismatch pattern).
        try {
          await _delete(deletedCounterIdsKey);
        } catch (_) {}
        try {
          await _write(deletedCounterOwnerKey, owner);
        } catch (_) {}
        return const {};
      }
      if (storedOwner == null) {
        // Unowned set: adopt it for the current account.
        try {
          await _write(deletedCounterOwnerKey, owner);
        } catch (_) {}
      }
      return ids;
    } catch (_) {
      return const {};
    }
  }

  /// Persists the tombstone set for [ownerEmail]. An empty set
  /// deletes the ids key (the owner key is kept/updated so the
  /// binding survives for the next write). Never throws.
  Future<void> setDeletedCounterIds(Set<String> ids,
      {String? ownerEmail}) async {
    final owner = _normalizeOwner(ownerEmail);
    try {
      if (ids.isEmpty) {
        await _delete(deletedCounterIdsKey);
      } else {
        final sorted = ids.toList()..sort();
        await _write(deletedCounterIdsKey, jsonEncode(sorted));
      }
    } catch (_) {}
    if (owner != null) {
      try {
        await _write(deletedCounterOwnerKey, owner);
      } catch (_) {}
    }
  }

  /// The set a WRITE (add/remove) merges against. An owned write
  /// uses the gated read (a positive mismatch has already dropped
  /// the foreign set there). A null-owner write comes from an
  /// email-less surface acting inside a live session — the delete
  /// it accompanies was computed from that session's own fresh
  /// pull — so it merges against the RAW stored set instead of
  /// the gated read: since Juno C2 a null-owner read of a bound
  /// set returns empty, and merging from empty would CLOBBER the
  /// session account's existing tombstones with just the new id.
  /// The stored owner binding is left untouched by null-owner
  /// writes (setDeletedCounterIds only stamps a non-null owner),
  /// and cross-account safety still comes from [clear] on
  /// logout, [clearDeletedCounterIds] on session expiry, and the
  /// owned read's mismatch drop.
  Future<Set<String>> _writeBaseDeletedCounterIds(String? ownerEmail) =>
      _normalizeOwner(ownerEmail) == null
          ? _readRawDeletedCounterIds()
          : getDeletedCounterIds(ownerEmail: ownerEmail);

  /// Adds one id to the tombstone set (idempotent). Never throws.
  Future<void> addDeletedCounterId(String id, {String? ownerEmail}) async {
    if (id.isEmpty) return;
    final ids = await _writeBaseDeletedCounterIds(ownerEmail);
    if (ids.contains(id)) return;
    await setDeletedCounterIds({...ids, id}, ownerEmail: ownerEmail);
  }

  /// Removes one id from the tombstone set. Used to roll a
  /// tombstone back when the delete push itself failed — the
  /// counter was never deleted server-side, so nothing may hide it.
  /// Never throws.
  Future<void> removeDeletedCounterId(String id,
      {String? ownerEmail}) async {
    final ids = await _writeBaseDeletedCounterIds(ownerEmail);
    if (!ids.contains(id)) return;
    await setDeletedCounterIds({...ids}..remove(id),
        ownerEmail: ownerEmail);
  }

  /// Wipes ONLY the two tombstone keys, leaving every other
  /// settings key untouched. Called on a forced session expiry
  /// (Juno C2): expiry is a logout-class event for account-bound
  /// data, but it must not reset the device-level preferences a
  /// full [clear] would — the next sign-in on this device keeps
  /// the user's theme / nav choices while inheriting NONE of the
  /// expired account's delete tombstones. Never throws.
  Future<void> clearDeletedCounterIds() async {
    for (final k in const [deletedCounterIdsKey, deletedCounterOwnerKey]) {
      try {
        await _delete(k);
      } catch (_) {}
    }
  }

  /// Wipes every settings key. Called on logout / account deletion so a
  /// next account never inherits this account's on-device choices.
  Future<void> clear() async {
    for (final k in const [
      showNavLabelsKey,
      themeModeKey,
      userContextHiddenKey,
      checkInReminderKey,
      lastSyncTimeKey,
      googleCalendarConnectedKey,
      googleCalendarEmailKey,
      googleAccountConnectedKey,
      googleAccountEmailKey,
      reportLastTypeKey,
      reportLastRange30dKey,
      reportLastExportKey,
      reportAppointmentDateKey,
      reportAppointmentTypeKey,
      deletedCounterIdsKey,
      deletedCounterOwnerKey,
    ]) {
      try {
        await _delete(k);
      } catch (_) {}
    }
  }
}
