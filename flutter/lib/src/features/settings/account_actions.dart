import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';

/// Round 29 — logout / delete-account flows, mirroring native
/// `SettingsViewModel.logout` (SettingsViewModel.kt:1148-1240) and
/// `deleteAccount` → `LogRepository.deleteAccountData()`
/// (LogRepository.kt:1432-1455) + `restartOnboarding` (:1082-1139):
///
/// - Logout: native first pushes all local data, then revokes the
///   refresh token server-side, then clears credentials + caches.
///   The Flutter Lab has no local-only record store (every record is
///   written through to the server at save time by the Quick Log /
///   tools flows), so there is nothing extra to push; the flow revokes
///   the token best-effort (native proceeds even when the revoke call
///   fails), then clears EVERYTHING account-bound on device.
/// - Delete: native calls `DELETE /api/auth/delete-account` FIRST and
///   only wipes locally on success; on failure the account and session
///   stay intact and the error is shown. Same order here.
///
/// Clearing (Juno standing note, Round 19c account-binding pattern):
/// the stored session AND every account-bound on-device cache —
/// [HomeDataCache], [QuickLogCache], [HeartDataCache], and the
/// Round 35 Today Summary stores [TodaySummaryCache] +
/// [TodayPlanStore] (Vera R35 re-review HIGH 2: their logout hooks
/// previously had no production caller) — plus the Settings store
/// and the backend's in-memory sync-pull cache, so no
/// previous-account data can render for the next account.
class AccountActions {
  final TabsBackend _backend;
  final SessionStore _sessionStore;
  final SettingsStore _settingsStore;
  final Future<void> Function() _clearCaches;

  AccountActions({
    TabsBackend? backend,
    SessionStore? sessionStore,
    SettingsStore? settingsStore,
    Future<void> Function()? clearCaches,
  })  : _backend = backend ?? TabsBackend(),
        _sessionStore = sessionStore ?? SessionStore(),
        _settingsStore = settingsStore ?? SettingsStore(),
        _clearCaches = clearCaches ?? _clearDefaultCaches;

  static Future<void> _clearDefaultCaches() async {
    // Each cache isolated: one failing clear must not leave the
    // other caches holding the previous account's data (R29b).
    try {
      await HomeDataCache.instance.clear();
    } catch (_) {}
    try {
      await QuickLogCache.instance.clear();
    } catch (_) {}
    try {
      await HeartDataCache.instance.clear();
    } catch (_) {}
    try {
      await TodaySummaryCache.instance.clear();
    } catch (_) {}
    try {
      await TodayPlanStore.instance.clear();
    } catch (_) {}
  }

  /// Test hook: clears the real cache singletons.
  static Future<void> clearDefaultCaches() => _clearDefaultCaches();

  /// Fault-isolated wipe (R29b Vera fix): every step is independently
  /// best-effort. Previously four sequential awaits meant a throw in
  /// [SessionStore.clear] (the only clear that did not swallow storage
  /// errors) skipped the caches + settings wipe entirely — leaving
  /// account data on device after "logout", and, after a server-side
  /// account delete, a live local session.
  Future<void> _clearEverything() async {
    try {
      _backend.invalidateSyncPull();
    } catch (_) {}
    try {
      await _sessionStore.clear();
    } catch (_) {}
    try {
      await _clearCaches();
    } catch (_) {}
    try {
      await _settingsStore.clear();
    } catch (_) {}
  }

  /// Native-parity logout. Always completes the local wipe (the server
  /// revoke is best-effort, exactly as native). Returns true when the
  /// server acknowledged the revoke.
  Future<bool> logout() async {
    var revoked = false;
    try {
      revoked = await _backend.logoutAccount();
    } catch (_) {
      revoked = false;
    }
    await _clearEverything();
    return revoked;
  }

  /// Native-parity delete: server first. On success, wipe locally and
  /// return true. On failure, change NOTHING locally and return false
  /// (the caller shows native's error state).
  Future<bool> deleteAccount() async {
    var ok = false;
    try {
      ok = await _backend.deleteAccount();
    } catch (_) {
      ok = false;
    }
    if (!ok) return false;
    // Native restartOnboarding also revokes via /api/auth/logout
    // before deleting; after a successful delete the token is dead,
    // so a revoke attempt is skipped and the local wipe proceeds.
    await _clearEverything();
    return true;
  }
}
