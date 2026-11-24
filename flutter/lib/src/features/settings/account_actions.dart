import 'dart:async';

import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/daily_score_refresh_owner.dart';
import 'package:tabs_lab/src/data/daily_score_sync.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/medication_change_event_outbox.dart';
import 'package:tabs_lab/src/data/onboarding_sync_outbox.dart';
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
import 'package:tabs_lab/src/data/weekly_snapshot_cache.dart';

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
///   The C-08 onboarding-sync outbox rides the same rule (its own
///   bounded flush in [logout], retention on an unconfirmed
///   flush, full wipe only on account deletion).
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
///
/// Bounded sign-out (logout-sync fix, Nov 24, 2026): EVERY awaited
/// leg of [logout] carries a bound, so sign-out visibly completes
/// within ~5 s worst case even when a leg wedges — the pre-fix
/// chain awaited the revoke and both storage clears unbounded, and
/// one wedged secure-storage channel future parked logout forever
/// behind a static dialog (Dad's Nov 24, 2026 report). The bounds:
/// [flushTimeout] per outbox flush (the two flushes run
/// concurrently), [revokeTimeout] on the revoke call (which
/// [TabsBackend.logoutAccount] also bounds internally), and a
/// per-leg bound on each wipe step in [_clearEverything] /
/// [_clearDefaultCaches]. A leg that hits its bound degrades to
/// background completion on the funnel's own unawaited precedent
/// (see the LeanTestSessionStore note in [_clearDefaultCaches]):
/// every store drops its in-memory / owner state synchronously
/// when its clear starts, so the account boundary holds even when
/// the storage future never lands, and a surviving disk blob
/// stays owner-guarded. When a flush is abandoned at its bound,
/// [LogEntryOutbox.beginSignOut] / [OnboardingSyncOutbox]'s twin
/// close the H1 race: the abandoned run stops posting and stops
/// mutating, so the F2 retain decision is made against a queue
/// that can no longer change underneath it.
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

  /// Per-flush bound in [logout]: each outbox gets this long to
  /// confirm its queue before the retain decision is made without
  /// it. The two flushes run concurrently, so the flush phase
  /// costs at most this much wall-clock (the pre-fix code ran them
  /// serially at 3 s each).
  static const Duration flushTimeout = Duration(seconds: 2);

  /// Bound on the best-effort server revoke in [logout]. The
  /// backend bounds its own legs internally too
  /// (TabsBackend.logoutStorageTimeout / logoutRequestTimeout);
  /// this call-site bound is the envelope that guarantees the
  /// sign-out deadline even if a future backend leg regresses.
  static const Duration revokeTimeout = Duration(seconds: 2);

  /// Per-leg bound for the session/settings clears in
  /// [_clearEverything]: a wedged storage channel degrades that
  /// leg to background completion instead of parking the wipe.
  static const Duration wipeLegTimeout = Duration(seconds: 1);

  /// Bound for the whole cache funnel leg in [_clearEverything].
  static const Duration cachesLegTimeout =
      Duration(milliseconds: 1500);

  /// Per-step bound inside [_clearDefaultCaches]: one wedged
  /// cache delete must not starve the steps behind it — each
  /// step's in-memory drop has already run synchronously by the
  /// time its future is awaited, so abandoning the await at this
  /// bound loses nothing the account boundary depends on.
  static const Duration cacheStepTimeout =
      Duration(milliseconds: 500);

  /// The in-flight [logout] run, if any (single-flight): a second
  /// invocation while one is running joins it instead of running
  /// the whole chain concurrently (the pre-fix dialog-dismiss +
  /// re-tap and dialog + session-expiry overlaps did exactly
  /// that).
  Future<bool>? _logoutInFlight;

  /// Awaits [future] up to [bound], swallowing every outcome —
  /// the bounded-wipe-step primitive: the caller's step is
  /// best-effort and fault-isolated by design, and a timeout
  /// degrades it to background completion (the future itself
  /// keeps running; its late completion or error harms nothing —
  /// every wipe step guards its own residue by owner).
  static Future<void> _bounded(Future<dynamic> future, Duration bound) async {
    try {
      await future.timeout(bound);
    } catch (_) {}
  }

  static Future<void> _clearDefaultCaches({
    bool retainUnconfirmedLogEntries = false,
  }) async {
    // Each cache isolated: one failing clear must not leave the
    // other caches holding the previous account's data (R29b).
    // Logout-sync (Nov 24, 2026): each awaited step is also
    // TIME-bounded via [_bounded] at [cacheStepTimeout] — one
    // WEDGED clear (a storage future that never completes, the
    // documented channel-wedge class) must not starve the steps
    // behind it either. Every store below drops its in-memory /
    // owner state synchronously when its clear starts, so the
    // abandoned await degrades to background completion of the
    // disk delete, and a surviving blob stays owner-guarded.
    await _bounded(HomeDataCache.instance.clear(), cacheStepTimeout);
    await _bounded(QuickLogCache.instance.clear(), cacheStepTimeout);
    // Optimistic logging (Oct 27, 2026): unconfirmed log entries
    // are account-bound health data — the wipe covers the outbox,
    // EXCEPT on the F2 retention path (logout / session expiry
    // with entries the server never confirmed), where the
    // owner-bound blob is retained for the same account's return.
    await _bounded(
      retainUnconfirmedLogEntries
          ? LogEntryOutbox.instance.retainUnconfirmed()
          : LogEntryOutbox.instance.clear(),
      cacheStepTimeout,
    );
    await _bounded(HeartDataCache.instance.clear(), cacheStepTimeout);
    await _bounded(TodaySummaryCache.instance.clear(), cacheStepTimeout);
    await _bounded(TodayPlanStore.instance.clear(), cacheStepTimeout);
    // Round 55: coach memory is account-bound device-local data —
    // the same wipe covers it.
    await _bounded(CoachMemoryStore.instance.clear(), cacheStepTimeout);
    // Audit 4e (Oct 27, 2026): migraine attack records are
    // account-bound device-local health data — the same wipe
    // covers them, the in-progress attack included.
    await _bounded(MigraineAttackStore.instance.clear(), cacheStepTimeout);
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
    await _bounded(
        LocalMigraineNotifier.cancelPostedAttack(), cacheStepTimeout);
    // R70 fix pass (Vera F1 / Juno C1): the historical health store
    // is account-bound all-time health data — logout / account
    // deletion must leave none of it on device.
    await _bounded(HealthHistoryStore.instance.clear(), cacheStepTimeout);
    // Daily Score server sync (Oct 28, 2026): the pending-push
    // queue is owner-stamped account data — the same wipe covers
    // it, and its generation bump aborts any in-flight hydration
    // so a merge cannot resurrect the wiped scores afterwards.
    // Deliberately NOT retained like the log-entry outbox: the
    // scores themselves are wiped with the history store above,
    // so a retained queue would be the only surviving copy of a
    // departed account's health data (the migraine-store wipe
    // precedent governs).
    await _bounded(DailyScoreSync.instance.clear(), cacheStepTimeout);
    // H1-07: the medication change-event outbox is owner-stamped
    // account data too — the same wipe covers it on explicit
    // logout / account deletion. (Session EXPIRY deliberately
    // does not wipe it: see main.dart's _onSessionExpired and the
    // outbox file header — the events exist nowhere else locally,
    // so the owner-stamped blob is retained for the same
    // account's return and dropped unsent by a different
    // account's sign-in.)
    // Deliberately NOT awaited, on the LeanTestSessionStore
    // precedent directly above: this funnel has no test-injected
    // storage for the outbox, so its delete reaches the real
    // FlutterSecureStorage channel — a channel future that
    // cannot complete in a caller's async zone would park the
    // whole wipe (and the logout) behind it. clear() drops the
    // in-memory queue and owner binding SYNCHRONOUSLY before its
    // first await, so the wipe takes effect here; only the blob
    // delete completes in the background, and a surviving blob
    // stays guarded (flush re-checks the owner, and login's
    // clearIfOwnerMismatch re-wipes a mismatched blob).
    unawaited(MedicationChangeEventOutbox.instance.clear());
    // C-08: the onboarding-sync outbox holds a staged finalize
    // payload that exists NOWHERE else (its direct posts failed)
    // — it gets the log-entry outbox's F2 treatment, not the
    // medication outbox's clear: in retain mode (logout whose
    // flush did not confirm every payload) the owner-stamped
    // blob is RETAINED for the same account's return and dropped
    // unsent by a different account's sign-in; in normal mode
    // (account deletion — the account is gone server-side, so
    // no session could ever legitimately receive the payload)
    // it is cleared with everything else. Deliberately NOT
    // awaited, on the two precedents directly above: this funnel
    // has no test-injected storage for the outbox, so its
    // storage futures reach the real channel — a channel future
    // that cannot complete in a caller's async zone would park
    // the whole wipe. Both operations drop/retain the in-memory
    // queue synchronously before their first await, and a
    // surviving blob stays guarded (flush re-checks the owner;
    // login's clearIfOwnerMismatch re-wipes a mismatched blob).
    if (retainUnconfirmedLogEntries) {
      unawaited(OnboardingSyncOutbox.instance.retainUnconfirmed());
    } else {
      unawaited(OnboardingSyncOutbox.instance.clear());
    }
    // Refresh-scope fix (Oct 20, 2026): the refresh owner's
    // pending outcomes live only in memory, but they belong to
    // the account too — logout / account deletion drops them
    // (and invalidates any in-flight refresh) with the store.
    try {
      DailyScoreRefreshOwner.instance.clear();
    } catch (_) {}
    // Weekly Snapshot session cache (Oct 30, 2026): the cached
    // week is account-bound health data held in app-session
    // memory — logout / reset / account deletion drops it (and
    // its owner binding) with the rest, so a departed account's
    // week never survives in memory behind the login funnel.
    try {
      WeeklySnapshotCache.instance.clear();
    } catch (_) {}
    // Round 65: cached extracted document text is account-bound
    // device-local medical text — the same wipe covers it.
    await _bounded(
        KnowledgeExtractionStore.instance.clear(), cacheStepTimeout);
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
    // Logout-sync (Nov 24, 2026): the three legs START together
    // and are awaited under per-leg bounds. Starting a leg runs
    // its synchronous prefix immediately — SessionStore.clear's
    // first delete, every cache's in-memory reset, SettingsStore
    // .clear's first delete — so all in-memory account state drops
    // NOW, and a wedged channel future in any one leg degrades
    // that leg to background completion instead of parking the
    // legs behind it (the pre-fix sequential chain let one wedge
    // starve every later clear, and the logout with it). The legs
    // touch disjoint stores, and each remains fault-isolated
    // exactly as in the sequential version (R29b): [_bounded]
    // swallows throws and timeouts alike.
    final sessionLeg = _startLeg(_sessionStore.clear, wipeLegTimeout);
    final cachesLeg = _startLeg(
      () => retainUnconfirmedLogEntries && _usesDefaultCaches
          ? _clearDefaultCaches(retainUnconfirmedLogEntries: true)
          : _clearCaches(),
      cachesLegTimeout,
    );
    final settingsLeg = _startLeg(_settingsStore.clear, wipeLegTimeout);
    await Future.wait([sessionLeg, cachesLeg, settingsLeg]);
  }

  /// Starts a wipe leg and bounds its await (see [_clearEverything]):
  /// a synchronous throw from the step itself is fault-isolated
  /// exactly like an asynchronous one.
  static Future<void> _startLeg(
    Future<void> Function() step,
    Duration bound,
  ) {
    final Future<void> future;
    try {
      future = step();
    } catch (_) {
      return Future<void>.value();
    }
    return _bounded(future, bound);
  }

  /// Native-parity logout. Always completes the local wipe (the server
  /// revoke is best-effort, exactly as native). Returns true when the
  /// server acknowledged the revoke.
  ///
  /// Single-flight (logout-sync fix): a second invocation while a
  /// run is in flight JOINS it — the same future is returned, so
  /// the chain (flushes, revoke, wipe) executes exactly once no
  /// matter how many callers pile on (dialog confirm + session
  /// expiry, a re-tap after a dismissed attempt, [resetAccountStatus]
  /// racing a manual logout).
  Future<bool> logout() {
    final inFlight = _logoutInFlight;
    if (inFlight != null) return inFlight;
    late final Future<bool> future;
    future = _logoutInternal().whenComplete(() {
      if (identical(_logoutInFlight, future)) _logoutInFlight = null;
    });
    _logoutInFlight = future;
    return future;
  }

  Future<bool> _logoutInternal() async {
    // Native push-first parity: give unconfirmed log entries their
    // last chance to reach the server before the token is revoked.
    // Best-effort, exactly like the revoke — and time-bounded, so a
    // wedged storage channel or a dead connection can never hold
    // the logout itself hostage. F2: the flush RESULT now decides
    // the outbox's fate — a flush that did not confirm every entry
    // (offline, timed out, threw) RETAINS the owner-bound blob for
    // the same account's return instead of wiping it silently; only
    // a fully confirmed flush earns the wipe.
    //
    // Logout-sync (Nov 24, 2026): the two flushes are independent
    // queues, so they run CONCURRENTLY under one [flushTimeout]
    // bound each (the pre-fix serial 3 s + 3 s could alone exceed
    // the whole sign-out budget).
    Future<bool> flushBounded(Future<bool> flush) async {
      try {
        return await flush.timeout(flushTimeout, onTimeout: () => false);
      } catch (_) {
        return false;
      }
    }

    final results = await Future.wait([
      flushBounded(LogEntryOutbox.instance.flush(_backend)),
      flushBounded(OnboardingSyncOutbox.instance.flush(_backend)),
    ]);
    final flushed = results[0];
    // C-08: the same push-first chance for a staged onboarding
    // finalize payload, on the same bound. The retain decision
    // below is the OR of both flushes: either payload left
    // unconfirmed keeps the wipe in retain mode, so neither
    // outbox's unconfirmed data is silently wiped on logout
    // (the F2 rule; lean-test retention already rides this same
    // flag).
    final onboardingFlushed = results[1];
    // H1: the flush phase is over — confirmed, failed, or ABANDONED
    // at the bound. From here the revoke runs and the retain
    // decision is computed, so any flush run still in flight must
    // stop posting and stop mutating its queue NOW (see
    // [LogEntryOutbox.beginSignOut]): the retain decision below is
    // then made against queues that can no longer change. When
    // both flushes confirmed, no run is in flight and the bumps
    // are no-ops for the wipe that follows (a flush that starts
    // later captures the new generation and runs normally).
    LogEntryOutbox.instance.beginSignOut();
    OnboardingSyncOutbox.instance.beginSignOut();
    // Bounded (logout-sync fix): the pre-fix revoke await had NO
    // timeout — its unbounded secure-storage reads could park
    // logout forever. The backend bounds its own legs internally;
    // this envelope keeps the sign-out deadline regardless.
    var revoked = false;
    try {
      revoked = await _backend
          .logoutAccount()
          .timeout(revokeTimeout, onTimeout: () => false);
    } catch (_) {
      revoked = false;
    }
    await _clearEverything(
        retainUnconfirmedLogEntries: !flushed || !onboardingFlushed);
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
    // C-08: the reset discards the pre-reset onboarding run, so
    // its staged finalize payload is discarded WITH it — cleared
    // here, after the false push landed and before [logout]'s
    // bounded flush could re-post the stale snapshot's
    // `onboardingComplete: true` over the reset's explicit false.
    // (On a failed push nothing above ran, so a failed reset
    // loses nothing.) Deliberately NOT awaited, on the
    // medication-outbox precedent in _clearDefaultCaches: this
    // funnel has no test-injected storage for the outbox, so an
    // awaited channel future could park the reset behind a
    // wedged storage channel. clear() drops the in-memory queue
    // SYNCHRONOUSLY before its first await, so a flush that
    // STARTS after this point sees an empty queue. That alone
    // does NOT cover a flush already in flight (an earlier
    // version of this comment claimed it did — Vera's E-review
    // P1 probe proved otherwise): the in-flight case is covered
    // by the outbox itself, which re-checks slot identity,
    // generation, and bound owner after its attempts-persist
    // await, immediately before dispatch, so this clear landing
    // in that window suppresses the stale post, and by the
    // generation-guarded persist, which cannot resurrect the
    // cleared blob after clear's delete. The blob delete
    // completes in the background, and a blob that somehow
    // survives stays guarded (the reset's next login routes
    // into onboarding, whose finalize restages fresh slots, and
    // the flush's recency/merge guards treat the stale payload
    // as superseded).
    unawaited(OnboardingSyncOutbox.instance.clear());
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
