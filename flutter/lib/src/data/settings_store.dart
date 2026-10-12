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
///   Native ALSO arms/cancels a 4 AM alarm when this flips; the Flutter
///   Lab has no alarm/notification scheduler, so here it persists the
///   preference only (flagged in the round report).
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

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  SettingsStore();

  @visibleForTesting
  SettingsStore.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required Future<void> Function(String key) delete,
  })  : _read = read,
        _write = write,
        _delete = delete;

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

  /// Wipes every settings key. Called on logout / account deletion so a
  /// next account never inherits this account's on-device choices.
  Future<void> clear() async {
    for (final k in const [
      showNavLabelsKey,
      themeModeKey,
      userContextHiddenKey,
      checkInReminderKey,
      lastSyncTimeKey,
    ]) {
      try {
        await _delete(k);
      } catch (_) {}
    }
  }
}
