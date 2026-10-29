import 'dart:async';

import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/daily_score_refresh_owner.dart';
import 'package:tabs_lab/src/data/daily_score_sync.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/lean_test_session.dart';
import 'package:tabs_lab/src/data/migraine_attack_store.dart';
import 'package:tabs_lab/src/data/migraine_notification.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';

/// Round 29 — logout / delete-account flows (plus the Oct 2026
/// founder-fix [resetAccountStatus], which deliberately diverges
/// from native — see its doc), mirroring native
/// `SettingsViewModel.logout` (SettingsViewModel.kt:1148-1240) and
/// `deleteAccount` → `LogRepository.deleteAccountData()`
/// (LogRepository.kt:1432-1455) + `restartOnboarding` (:1082-1139):
///
/// - Logout: native first pushes all local data, then revokes the
///   refresh token server-side, then clears credentials + caches.
///   Since the optimistic-logging change (Oct 27, 2026) the app DOES
///   have one local-first record store — the log-entry outbox — so
///   logout first makes a best-effort flush attempt for any
///   unconfirmed entries (native's push-first order), then revokes
///   the token best-effort (native proceeds even when the revoke call
///   fails), then clears EVERYTHING account-bound on device — with
///   one F2 exception: when the flush did NOT confirm every entry
///   (offline logout, dead connection), the outbox is RETAINED
///   owner-bound instead of wiped, so the same account's next
///   session restores and flushes its own pending entries. A
///   different account signing in drops them via the outbox's
///   owner-mismatch enforcement before they can render or push.
///   Account deletion keeps the full wipe: the account is gone
///   server-side, so there is no session for entries to return to.
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

  /// Whether the cache wipe is the production funnel. The F2
  /// retention variant exists only there — an injected wipe (tests)
  /// owns its own behavior and runs as-is.
  final bool _usesDefaultCaches;

  AccountActions({
    TabsBackend? backend,
    SessionStore? sessionStore,
    SettingsStore? settingsStore,
    Future<void> Function()? clearCaches,
  })  : _backend = backend ?? TabsBackend(),
        _sessionStore = sessionStore ?? SessionStore(),
        _settingsStore = settingsStore ?? SettingsStore(),
        _usesDefaultCaches = clearCaches == null,
        _clearCaches = clearCaches ?? _clearDefaultCaches;

  static Future<void> _clearDefaultCaches({
    bool retainUnconfirmedLogEntries = false,
  }) async {
    // Each cache isolated: one failing clear must not leave the
    // other caches holding the previous account's data (R29b).
    try {
      await HomeDataCache.instance.clear();
    } catch (_) {}
    try {
      await QuickLogCache.instance.clear();
    } catch (_) {}
    // Optimistic logging (Oct 27, 2026): unconfirmed log entries
    // are account-bound health data — the wipe covers the outbox,
    // EXCEPT on the F2 retention path (logout / session expiry
    // with entries the server never confirmed), where the
    // owner-bound blob is retained for the same account's return.
    try {
      if (retainUnconfirmedLogEntries) {
        await LogEntryOutbox.instance.retainUnconfirmed();
      } else {
        await LogEntryOutbox.instance.clear();
      }
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
    // Round 55: coach memory is account-bound device-local data —
    // the same wipe covers it.
    try {
      await CoachMemoryStore.instance.clear();
    } catch (_) {}
    // Audit 4e (Oct 27, 2026): migraine attack records are
    // account-bound device-local health data — the same wipe
    // covers them, the in-progress attack included.
    try {
      await MigraineAttackStore.instance.clear();
    } catch (_) {}
    // Phase 1 item 6: the lean-test session is account-bound
    // device-local health data — the same wipe covers it, with
    // the F1/F2 retention exception mirroring the outbox directly
    // above: when this funnel runs in retain mode (logout whose
    // flush did not confirm every entry), a lean blob holding a
    // completed-pending entry is RETAINED owner-bound on the same
    // terms — the same account's next session retries it, a
    // different account's sign-in drops it via owner mismatch
    // before any load or retry can serve it. In normal mode the
    // wipe runs as before.
    // Deliberately NOT awaited in either mode (the
    // LogEntryOutbox blob-delete rule, and main.dart's
    // session-expiry treatment of this same store): the store has
    // no test-injected storage in this funnel, so its storage
    // futures reach the real FlutterSecureStorage channel — a
    // channel future that cannot complete in a caller's async
    // zone (a wedged channel in production, the fake-async zone
    // in widget tests) would park this whole wipe behind it:
    // every later clear, the settings clear, and the logout
    // itself would never run (settings_r29: onLogout never
    // fired). Both operations still take effect HERE, in
    // sequence: each drops the owner binding synchronously before
    // returning, and retainUnconfirmed decides from in-memory
    // state when it is known; only async completion is not
    // awaited. Neither future can complete with an error (the
    // store swallows storage errors), and a surviving blob stays
    // guarded — load() serves nothing unbound or mismatched and
    // login's clearIfOwnerMismatch re-wipes a mismatched blob.
    if (retainUnconfirmedLogEntries) {
      unawaited(LeanTestSessionStore.instance.retainUnconfirmed());
    } else {
      unawaited(LeanTestSessionStore.instance.clearAndUnbind());
    }
    // Vera 4e follow-up: wipe mid-attack must not orphan the
    // ongoing notification; its tap would load a wiped store.
    try {
      await LocalMigraineNotifier.cancelPostedAttack();
    } catch (_) {}
    // R70 fix pass (Vera F1 / Juno C1): the historical health store
    // is account-bound all-time health data — logout / account
    // deletion must leave none of it on device.
    try {
      await HealthHistoryStore.instance.clear();
    } catch (_) {}
    // Daily Score server sync (Oct 28, 2026): the pending-push
    // queue is owner-stamped account data — the same wipe covers
    // it, and its generation bump aborts any in-flight hydration
    // so a merge cannot resurrect the wiped scores afterwards.
    // Deliberately NOT retained like the log-entry outbox: the
    // scores themselves are wiped with the history store above,
    // so a retained queue would be the only surviving copy of a
    // departed account's health data (the migraine-store wipe
    // precedent governs).
    try {
      await DailyScoreSync.instance.clear();
    } catch (_) {}
    // Refresh-scope fix (Oct 20, 2026): the refresh owner's
    // pending outcomes live only in memory, but they belong to
    // the account too — logout / account deletion drops them
    // (and invalidates any in-flight refresh) with the store.
    try {
      DailyScoreRefreshOwner.instance.clear();
    } catch (_) {}
    // Round 65: cached extracted document text is account-bound
    // device-local medical text — the same wipe covers it.
    try {
      await KnowledgeExtractionStore.instance.clear();
    } catch (_) {}
    // Round 52 — single widget-clear funnel: the HomeDataCache
    // clear at the top of this sequence IS the widget clear (it
    // fire-and-forgets WidgetSync.clear() — unawaited inside the
    // cache, so the widget bridge can never wedge the wipe, the
    // R50 stuck-channel concern). The Round 50 duplicate explicit
    // WidgetSync.clear() here was removed so logout / account
    // delete requests exactly ONE widget update end-to-end.
  }

  /// Test hook: clears the real cache singletons.
  static Future<void> clearDefaultCaches({
    bool retainUnconfirmedLogEntries = false,
  }) =>
      _clearDefaultCaches(
        retainUnconfirmedLogEntries: retainUnconfirmedLogEntries,
      );

  /// Fault-isolated wipe (R29b Vera fix): every step is independently
  /// best-effort. Previously four sequential awaits meant a throw in
  /// [SessionStore.clear] (the only clear that did not swallow storage
  /// errors) skipped the caches + settings wipe entirely — leaving
  /// account data on device after "logout", and, after a server-side
  /// account delete, a live local session.
  Future<void> _clearEverything({
    bool retainUnconfirmedLogEntries = false,
  }) async {
    try {
      _backend.invalidateSyncPull();
    } catch (_) {}
    try {
      await _sessionStore.clear();
    } catch (_) {}
    try {
      if (retainUnconfirmedLogEntries && _usesDefaultCaches) {
        await _clearDefaultCaches(retainUnconfirmedLogEntries: true);
      } else {
        await _clearCaches();
      }
    } catch (_) {}
    try {
      await _settingsStore.clear();
    } catch (_) {}
  }

  /// Native-parity logout. Always completes the local wipe (the server
  /// revoke is best-effort, exactly as native). Returns true when the
  /// server acknowledged the revoke.
  Future<bool> logout() async {
    // Native push-first parity: give unconfirmed log entries their
    // last chance to reach the server before the token is revoked.
    // Best-effort, exactly like the revoke — and time-bounded, so a
    // wedged storage channel or a dead connection can never hold
    // the logout itself hostage. F2: the flush RESULT now decides
    // the outbox's fate — a flush that did not confirm every entry
    // (offline, timed out, threw) RETAINS the owner-bound blob for
    // the same account's return instead of wiping it silently; only
    // a fully confirmed flush earns the wipe.
    var flushed = false;
    try {
      flushed = await LogEntryOutbox.instance
          .flush(_backend)
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
    } catch (_) {
      flushed = false;
    }
    var revoked = false;
    try {
      revoked = await _backend.logoutAccount();
    } catch (_) {
      revoked = false;
    }
    await _clearEverything(retainUnconfirmedLogEntries: !flushed);
    return revoked;
  }

  /// Reset Account Status (founder fix, Oct 2026). Until now this
  /// button was wired to [deleteAccount] — a faithful port of native,
  /// whose `restartOnboarding` also deletes the account server-side
  /// behind a "Reset Account Status" label. The founder's ruling:
  /// reset must mean RESET, not delete — the account, its password,
  /// and all its data survive; only the onboarding/setup status is
  /// cleared, so the next sign-in runs the setup flow again.
  ///
  /// Mechanics: the server-side status is the profile field
  /// `onboardingComplete` (`user_profiles.onboarding_complete`).
  /// An explicit `false` push persists server-side (the profile
  /// upsert's COALESCE keeps an explicit false; verified live), and
  /// the sync pull + login responses then report it. Order mirrors
  /// [deleteAccount]'s fail-closed shape: the server write lands
  /// FIRST — on an ordinary failure nothing changes locally and
  /// false returns. One named exception (Vera MEDIUM, Oct 2026 —
  /// [deleteAccount] shares it): if the push's 401 ends in a
  /// DEFINITIVE refresh failure, the backend layer itself clears
  /// the session and fires the global session-expired logout before
  /// the push reports failure, so the user lands logged out anyway.
  /// That state is consistent, not corrupt: the server flag was
  /// never written, so the next login routes home as usual.
  /// On success the full logout wipe runs (refresh-token revoke
  /// best-effort, session + every account-bound cache cleared;
  /// AppFlow's logout path also wipes the on-device onboarding
  /// flags), so the next login starts from the same clean slate as
  /// a fresh registration. AppFlow's login routing honors the
  /// explicit server `false` and enters onboarding instead of
  /// marking the account complete (see main.dart).
  Future<bool> resetAccountStatus() async {
    var ok = false;
    try {
      ok = await _backend.postSyncProfile({'onboardingComplete': false});
    } catch (_) {
      ok = false;
    }
    if (!ok) return false;
    await logout();
    return true;
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
