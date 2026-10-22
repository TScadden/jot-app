import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/billing_play_store.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/first_run_sync.dart';
import 'package:tabs_lab/src/data/knowledge_documents.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/launch_trace.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/daily_score_background.dart';
import 'package:tabs_lab/src/data/daily_score_refresh_owner.dart';
import 'package:tabs_lab/src/data/refresh_keep_alive.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_flow.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/splash/splash_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';

void main() async {
  // Round 60 — launch timeline starts here (see launch_trace.dart;
  // in-memory only, printed only under --dart-define=LAUNCH_TRACE).
  LaunchTrace.instance.mark(LaunchTrace.processStart);
  // Round 16 — warm the home-data cache before the first frame so a
  // cold start shows last-known numbers instantly instead of "--".
  // Never throws; a missing/corrupt cache just starts empty.
  WidgetsFlutterBinding.ensureInitialized();
  // Round 19c fix (Vera BLOCKING 1) — account-bound warm: read the
  // stored session account first, and warm each cache against it.
  // A blob owned by a different account (or by no recorded account)
  // is dropped inside warmFromDisk instead of loaded, so a cold
  // start can never seed one account's rows into another's session.
  // The login-success hook enforces the same check again. Never
  // throws; an unreadable session just warms unbound.
  String? sessionEmail;
  try {
    sessionEmail = await SessionStore().readEmail();
  } catch (_) {
    sessionEmail = null;
  }
  // Round 60 — the two cache warms are independent disk reads (each
  // bound to the same already-read session email), so they run in
  // PARALLEL: pre-frame warm time is the max of the two reads, not
  // their sum. The warm itself stays pre-frame on purpose — it is
  // the snapshot-first paint mechanism (Round 16/19c): Home's first
  // frame renders these values, so they must be in memory before
  // runApp. Both warms never throw.
  await Future.wait([
    HomeDataCache.instance.warmFromDisk(currentEmail: sessionEmail),
    // Round 19c — same warm for Quick Log: cold starts seed last-known
    // categories / recents / count / membership instead of skeletons.
    QuickLogCache.instance.warmFromDisk(currentEmail: sessionEmail),
    // R70 fix pass (Vera F1 / Juno C1) — same account-bound warm for
    // the historical health store: a blob owned by a different
    // account is dropped here instead of seeding another account's
    // all-time history + Daily Scores into this session.
    HealthHistoryStore.instance.warmFromDisk(currentEmail: sessionEmail),
  ]);
  LaunchTrace.instance.mark(LaunchTrace.cachesWarmed);
  // V-1 correction — the ONE app-level notification bootstrap:
  // plugin.initialize for the foreground isolate happens here,
  // once, with the dispatching response callback (score payloads
  // route to the Daily Score tap handler; anything else keeps
  // the reminder service's previous no-op behavior). Both
  // notification services join this initialization instead of
  // initializing on their own — a screen building a fresh
  // reminder service can no longer wipe score tap routing
  // in-session. Fire-and-forget: app start never blocks on it,
  // and a failure leaves the in-flight state cleared so the
  // first service use retries.
  unawaited(() async {
    try {
      await NotificationBootstrap.initialize(
          FlutterLocalNotificationsPlugin());
    } catch (_) {
      // Silent: notifications are an enhancement; the app must
      // start identically without them.
    }
  }());
  // Round 52 — re-publish the widget on EVERY app start, once,
  // unawaited: a signed-in snapshot when a session exists and the
  // warmed cache holds one, the signed-out payload otherwise. This
  // closes the after-update orphan gap (a new build's first launch
  // re-binds a placed widget to current state) and the welcome-route
  // gap (a cold start that never mounts Home still refreshes the
  // widget). Fire-and-forget; WidgetSync never throws.
  unawaited(WidgetSync.republishAppStart(
    hasSession: sessionEmail != null,
    snapshot: HomeDataCache.instance.snapshot,
  ));
  runApp(const TabsLabApp());
  LaunchTrace.instance.mark(LaunchTrace.runAppCalled);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    LaunchTrace.instance.mark(LaunchTrace.firstFrame);
  });
}

class TabsLabApp extends StatelessWidget {
  const TabsLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tabs Lab',
      debugShowCheckedModeBanner: false,
      // Round 22 — the app's first theme carried only the slide
      // pageTransitionsTheme (navigation flash fix) and the scaffold
      // background backstop. Round 28 — notelDarkTheme() (see
      // notel_theme.dart) keeps both and adds the full dark
      // ColorScheme + stock-surface sub-themes from the Notel
      // palette, so built-in Material surfaces (date picker, dialogs,
      // menus, snackbars) render dark instead of falling back to the
      // default light theme. Screen colors stay per-widget literals.
      theme: notelDarkTheme(),
      home: const AppFlow(),
    );
  }
}

/// Round 5 app flow: splash entry (650ms) -> hold (1200ms) -> native-spec
/// exit (650ms slide-up, FastOutSlowIn, alpha holding through the first 60%
/// of travel then fading) revealing the welcome screen underneath.
/// Welcome Register -> login screen in register mode;
/// welcome Log In -> login screen in login mode; login back -> welcome.
/// Login "Log In" performs REAL authentication against
/// https://api.jottracker.com (see AuthApiClient); on success the session
/// is stored securely and the user lands on the home screen, which shows
/// a "Logged in as {email}" indicator.
///
/// Round 32 — onboarding. A real REGISTRATION (LoginScreen's
/// onRegisterSuccess) enters [OnboardingFlow] at the consent step —
/// native routes register success to `consent` because the new
/// account has not completed onboarding, while email/Google LOGIN
/// success marks onboarding complete and lands home (native
/// `LoginViewModel`). Cold start layers the same native splash rule
/// over Round 31's session restore: see [_AppFlowState._restoreSession].
class AppFlow extends StatefulWidget {
  /// Injectable for tests; defaults to the real backend client.
  final AuthApiClient? authApi;

  /// Injectable for tests; defaults to flutter_secure_storage.
  final SessionStore? sessionStore;

  /// Injectable for tests; defaults to the real Open-Meteo client.
  final WeatherApiClient? weatherApi;

  /// Injectable for tests; defaults to the real geolocator wrapper.
  final LocationService? locationService;

  /// Injectable for tests; defaults to a real HealthConnectService.
  /// Shared with the connections screen (and future onboarding).
  final HealthConnectService? healthConnectService;

  /// Round 32 — injectable for tests; defaults to secure storage.
  final OnboardingStore? onboardingStore;

  /// Round 32 — injectable for tests; defaults to a real backend
  /// bound to the flow's session store.
  final TabsBackend? tabsBackend;

  /// Round 32 — injectable for tests; defaults to the real local
  /// notification service (Round 30).
  final ReminderNotificationService? notificationService;

  const AppFlow(
      {super.key,
      this.authApi,
      this.sessionStore,
      this.weatherApi,
      this.locationService,
      this.healthConnectService,
      this.onboardingStore,
      this.tabsBackend,
      this.notificationService});

  @override
  State<AppFlow> createState() => _AppFlowState();
}

enum _FlowStage { welcome, login, resolving, onboarding, home }

class _AppFlowState extends State<AppFlow>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _entryMs = 650;
  static const _holdMs = 1200;
  static const _exitMs = 650;

  late final AnimationController _exitController;
  late final Animation<double> _exit;
  bool _splashVisible = true;
  _FlowStage _stage = _FlowStage.welcome;
  bool _loginIsRegister = true;
  String? _loggedInEmail;

  // Round 32 — onboarding state for this flow (injected in tests).
  late final OnboardingStore _onboardingStore;
  late final TabsBackend _tabsBackend;
  OnboardingStep _onboardingStep = OnboardingStep.consent;

  void _goLogin(bool isRegister) {
    setState(() {
      _loginIsRegister = isRegister;
      _stage = _FlowStage.login;
    });
  }

  void _goWelcome() {
    setState(() => _stage = _FlowStage.welcome);
  }

  // Round 29 (minimal, additive): Settings logout / account deletion
  // has already cleared the session and every account-bound cache by
  // the time this fires; return to the welcome flow and drop the
  // in-memory email so no previous-account state can render.
  //
  // Round 32 (additive): also wipe the onboarding store. Native's
  // restartOnboarding (the Settings "Reset Account Status" path)
  // calls clearCredentials() — a FULL DataStore clear — before
  // logging out, so the next account on the device starts onboarding
  // from a clean slate; plain native logout leaves the flags, but a
  // Flutter re-login rewrites them all on success (see
  // _onLoginSuccess / _onRegisterSuccess), so wiping here is
  // outcome-identical and keeps reset behavior exact.
  void _onLogout() {
    unawaited(_onboardingStore.clear());
    // Founder fix (Oct 2026, Vera BLOCKER) — drop this flow's
    // backend pull cache too: TabsBackend.fetchSyncPull serves a
    // 5-minute TTL cache that is NOT keyed by account, so a stale
    // body from the account that just signed out could otherwise
    // answer the NEXT account's login routing (and, after a reset,
    // silently undo it). The resolver also invalidates before
    // reading; this is the defense-in-depth half.
    _tabsBackend.invalidateSyncPull();
    setState(() {
      _loggedInEmail = null;
      _stage = _FlowStage.welcome;
    });
  }

  // Round 31 — the session store this flow reads for cold-start
  // restore (the injected one in tests, a real one otherwise).
  late final SessionStore _sessionStore;

  // Round 31 — cold-start session restore, native parity
  // (SplashScreen.checkAuthState): stored session PRESENCE alone
  // routes to home. No network validation at startup, and the
  // splash is never blocked on this read — an offline cold start
  // lands in Main with the stored session, and the backend's
  // 401→refresh path (TabsBackend) sorts out token expiry on the
  // first real call. No stored token → current welcome behavior.
  //
  // Round 32 — onboarding gate, layered INSIDE this restore (the
  // restore's mechanics are unchanged: presence check, no network,
  // splash never blocked, welcome-stage guard). Native's full
  // splash rule (SplashScreen.checkAuthState reads loggedIn +
  // onboardingComplete; the MainActivity splash handler then checks
  // hasConsented / introConsultationSeen) routes a signed-in user:
  //   !hasConsented → consent · !introSeen → consultation_intro ·
  //   !onboardingComplete → profile_setup · else → today.
  // The gate applies only when onboarding state exists on this
  // device: a pre-Round-32 stored session has none, and native marks
  // such existing accounts complete (login and pull both set the
  // flag — register was a no-op before Round 32, so every stored
  // session came through login/Google). Legacy sessions therefore
  // keep Round 31's straight-to-home landing and are backfilled
  // complete, instead of dropping an existing user into onboarding.
  // Round 60 — the display-only email read, isolated in its own
  // try/catch (Round 31 fix pass, Vera NIT 2): a storage failure
  // reading it must not abort a restore backed by a valid token, so
  // route on with a null email.
  Future<String?> _readEmailOrNull() async {
    try {
      return await _sessionStore.readEmail();
    } catch (_) {
      return null;
    }
  }

  // Round 60 — the Round 32 onboarding gate as one future, so the
  // restore can run it CONCURRENTLY with the email read instead of
  // behind it. Same semantics as the sequential chain it replaces:
  // local reads only, no network; any failure → Round 31 behavior
  // (hasState false, no resume step, straight home). The three flag
  // reads are independent of each other, so they also run in
  // parallel inside the gate (sequential sum → parallel max).
  Future<({bool hasState, OnboardingStep? resumeStep})>
      _readOnboardingGate() async {
    try {
      final hasState = await _onboardingStore.hasAnyState();
      if (!hasState) return (hasState: false, resumeStep: null);
      final flags = await Future.wait([
        _onboardingStore.getHasConsented(),
        _onboardingStore.getIntroConsultationSeen(),
        _onboardingStore.getOnboardingComplete(),
      ]);
      final OnboardingStep? resumeStep = !flags[0]
          ? OnboardingStep.consent
          : !flags[1]
              ? OnboardingStep.consultationIntro
              : !flags[2]
                  ? OnboardingStep.profileSetup
                  : null;
      return (hasState: true, resumeStep: resumeStep);
    } catch (_) {
      // Unreadable flags → Round 31 behavior (home).
      return (hasState: false, resumeStep: null);
    }
  }

  Future<void> _restoreSession() async {
    try {
      final token = await _sessionStore.readToken();
      if (token == null || token.trim().isEmpty) return;
      // Round 31 fix pass (Vera NIT 2): the email read is isolated
      // (see _readEmailOrNull). A TOKEN-read failure keeps the outer
      // behavior: fall to welcome, without clearing anything.
      //
      // Round 60 — email ∥ onboarding gate: both are local storage
      // reads off the same token decision and neither depends on the
      // other, so they run concurrently. Session validation remains
      // exactly what Round 31 made it: stored-session PRESENCE only,
      // no network round-trip at launch, ever.
      final emailFuture = _readEmailOrNull();
      final gateFuture = _readOnboardingGate();
      final email = await emailFuture;
      final gate = await gateFuture;
      final hasState = gate.hasState;
      final resumeStep = gate.resumeStep;
      // If the user already moved past welcome (or the widget is
      // gone), the restore has nothing to do.
      if (!mounted || _stage != _FlowStage.welcome) return;
      LaunchTrace.instance.mark(LaunchTrace.sessionRestored);
      if (!hasState) {
        // Legacy (pre-Round-32) session: backfill the flags complete,
        // mirroring native's login/pull marking (see the header).
        unawaited(_backfillLegacyOnboarding());
      }
      if (resumeStep != null) {
        // Native fires pullAllData in the background for a signed-in
        // cold start (SplashViewModel); its profile handling can
        // mark onboarding complete server-side truth — reconcile the
        // local flag for the NEXT launch (native does not re-route
        // mid-onboarding either).
        unawaited(_reconcileOnboardingFromServer());
        setState(() {
          _loggedInEmail = email;
          _onboardingStep = resumeStep;
          _stage = _FlowStage.onboarding;
        });
      } else {
        setState(() {
          _loggedInEmail = email;
          _stage = _FlowStage.home;
        });
        // TAKEOVER Phase 4 — a restored session landing home is a
        // first run after install/update until proven otherwise:
        // rebuild the reminder schedules once (see _kickFirstRunResync).
        _kickFirstRunResync();
        // App-open sync: a cold start landing home is an app open.
        _triggerAppOpenCapture();
      }
    } catch (_) {
      // Unreadable store → fresh-install behavior (welcome).
    }
  }

  // Round 32 — marks a pre-onboarding stored session complete, the
  // same end state native reaches via LoginViewModel.login (sets
  // onboardingComplete) and SyncManager.pullAllData (sets it when the
  // server profile says so, or when entries/categories exist).
  Future<void> _backfillLegacyOnboarding() async {
    try {
      await _onboardingStore.setHasConsented(true);
      await _onboardingStore.setIntroConsultationSeen(true);
      await _onboardingStore.setOnboardingComplete(true);
    } catch (_) {}
  }

  // Round 32 — background server reconciliation for a resumed
  // onboarding (native: SplashViewModel fires pullAllData when
  // logged in; SyncManager.pullAllData sets onboardingComplete=true
  // when the pulled profile has onboardingComplete=true, or when the
  // account already has entries/categories). Local-flag only; the
  // current routing decision is never revisited mid-flow.
  Future<void> _reconcileOnboardingFromServer() async {
    try {
      final body = await _tabsBackend.fetchSyncPull();
      if (body == null) return;
      final profile = body['profile'];
      // Founder fix (Oct 2026): an EXPLICIT server false is
      // authoritative — it means a reset account (Settings → Reset
      // Account Status) or an account still mid-onboarding. The
      // has-data heuristic below must not silently mark such an
      // account complete behind its back on a cold start, or a
      // reset user who pauses mid-setup would never finish it.
      if (profile is Map && profile['onboardingComplete'] == false) {
        return;
      }
      final serverComplete =
          profile is Map && profile['onboardingComplete'] == true;
      final entries = body['entries'];
      final categories = body['categories'];
      final hasData = (entries is List && entries.isNotEmpty) ||
          (categories is List && categories.isNotEmpty);
      if (serverComplete || hasData) {
        await _onboardingStore.setOnboardingComplete(true);
      }
    } catch (_) {}
  }

  // Round 31 — a definitive refresh failure discovered later by any
  // TabsBackend call. The backend wrapper has ALREADY cleared the
  // SessionStore (it is the single layer responsible for that);
  // here we only drop the account-bound in-memory caches and route
  // back to welcome via the existing logout mechanics.
  void _onSessionExpired() {
    unawaited(HomeDataCache.instance.clear());
    unawaited(QuickLogCache.instance.clear());
    // R70 fix pass (Vera F1 / Juno C1) — the historical health store
    // is account-bound too: session expiry leaves none of the expired
    // account's all-time history or Daily Scores on device.
    unawaited(HealthHistoryStore.instance.clear());
    // Refresh-scope fix (Oct 20, 2026): the app-scoped Daily
    // Score refresh owner's pending outcomes are in-memory only,
    // but they are account-bound too — session expiry drops them
    // (and invalidates any in-flight refresh) alongside the store.
    DailyScoreRefreshOwner.instance.clear();
    // Vera R35 re-review HIGH 2: the Today Summary stores are
    // account-bound too — a session expiry must leave none of the
    // expired account's summary on device (R29b standard). Each
    // clear is independently best-effort, like the two above.
    unawaited(TodaySummaryCache.instance.clear());
    unawaited(TodayPlanStore.instance.clear());
    // Round 55: coach memory is account-bound too — session expiry
    // wipes it like the other caches.
    unawaited(CoachMemoryStore.instance.clear());
    // Round 65: cached extracted document text is account-bound too.
    unawaited(KnowledgeExtractionStore.instance.clear());
    // Correction round (Juno C2): the SettingsStore counter-delete
    // TOMBSTONES are account-bound too, and this path previously
    // never touched SettingsStore — a forced expiry left the
    // expired account's tombstone keys on device, where an
    // email-less surface (Research → Settings) could read them
    // against a different account. Targeted wipe of just the two
    // tombstone keys: session expiry must not reset the device's
    // theme / nav preferences (the full SettingsStore.clear runs
    // on explicit logout / account deletion via AccountActions).
    unawaited(SettingsStore().clearDeletedCounterIds());
    // Round 52 — single widget-clear funnel: HomeDataCache.clear()
    // above IS the widget clear (it fire-and-forgets
    // WidgetSync.clear()); the Round 50 duplicate explicit call
    // here was removed so session expiry requests exactly ONE
    // widget update end-to-end.
    if (!mounted) return;
    _onLogout();
  }

  // Round 5: real login succeeded — the session is already in secure
  // storage (LoginScreen handles that); record the email for the home
  // indicator and navigate.
  //
  // Round 19c fix (Vera BLOCKING 1): BEFORE the shell can mount, drop
  // any cached snapshot owned by a different account. The memory wipe
  // inside clearIfOwnerMismatch runs synchronously before its first
  // await, so by the time setState mounts the shell below, a previous
  // account's Quick Log rows / home numbers are already gone and the
  // first frame can only show skeletons / honest empty states. The
  // disk wipe completes in the background. HomeDataCache gets the
  // same clear-on-mismatch for parity (Vera named it in the same
  // fix). Both calls also bind the new account, so subsequent loads
  // stamp their cache blobs with this owner.
  void _onLoginSuccess(String email) {
    unawaited(QuickLogCache.instance.clearIfOwnerMismatch(email));
    unawaited(HomeDataCache.instance.clearIfOwnerMismatch(email));
    // R70 fix pass (Vera F1 / Juno C1) — same owner-mismatch
    // enforcement for the historical health store.
    unawaited(HealthHistoryStore.instance.clearIfOwnerMismatch(email));
    // Refresh-scope fix (Oct 20, 2026): same enforcement for the
    // refresh owner's in-memory pending outcomes — synchronous,
    // so a previous account's deferred outcome is gone before the
    // shell mounts, exactly like the store's memory wipe above.
    DailyScoreRefreshOwner.instance.clearIfOwnerMismatch(email);
    // Vera R35 re-review HIGH 2: the Round 35 Today Summary stores
    // join the same owner-mismatch enforcement — a previous
    // account's cached summary / plan state must be gone before
    // the shell mounts for the new account.
    unawaited(TodaySummaryCache.instance.clearIfOwnerMismatch(email));
    unawaited(TodayPlanStore.instance.clearIfOwnerMismatch(email));
    unawaited(CoachMemoryStore.instance.clearIfOwnerMismatch(email));
    unawaited(
        KnowledgeExtractionStore.instance.clearIfOwnerMismatch(email));
    // Round 32 — native parity: email login and Google sign-in (both
    // modes) mark onboarding complete (LoginViewModel.login /
    // loginWithGoogleAccount call setOnboardingComplete(true)), and
    // MainActivity's onLoginSuccess(true) branch also sets
    // hasConsented + introConsultationSeen before navigating home.
    //
    // Founder fix (Oct 2026) — one deliberate exception: when the
    // account's server profile carries onboardingComplete EXPLICITLY
    // false, the account was reset (Settings → Reset Account Status)
    // or never finished setup, and the login routes into onboarding
    // like a fresh registration instead. The routing resolves in
    // _resolveLoginRoute; the owner-mismatch clears above have
    // already run synchronously, so no previous-account snapshot can
    // render on either destination. The stage moves to `resolving`
    // synchronously, unmounting the login form so nothing on it can
    // race the decision (Vera HIGH).
    if (!mounted) return;
    setState(() => _stage = _FlowStage.resolving);
    unawaited(_resolveLoginRoute(email));
  }

  /// Founder fix (Oct 2026) — post-login routing. The reset state
  /// is read from the sync pull (the same body
  /// [_reconcileOnboardingFromServer] reconciles from): only an
  /// explicit boolean `false` counts. A profile with the flag true,
  /// null, or absent — every legacy account, including ones whose
  /// profile row predates the flag — keeps the historic
  /// mark-complete-and-go-home behavior, and a failed pull falls
  /// back to it too rather than locking the user out of their data.
  /// (On that fallback the local flags are stamped complete, so the
  /// reset takes effect at the next logout → login cycle instead —
  /// the server flag stays false until setup completes and pushes
  /// true, so the reset is deferred, never lost.)
  Future<void> _resolveLoginRoute(String email) async {
    // Vera BLOCKER: fetchSyncPull's TTL cache is per-instance and
    // not keyed by account — without this, a login within 5 minutes
    // of a previous session's pull reads the OLD account state (a
    // reset performed moments ago would be silently undone, and a
    // cached false could drop the next account into onboarding).
    _tabsBackend.invalidateSyncPull();
    var serverReset = false;
    try {
      final body = await _tabsBackend.fetchSyncPull();
      final profile = body?['profile'];
      serverReset =
          profile is Map && profile['onboardingComplete'] == false;
    } catch (_) {
      serverReset = false;
    }
    // Vera HIGH: while the pull was in flight the world can change
    // — a definitive refresh failure inside this very pull fires
    // _onSessionExpired → _onLogout (stage leaves `resolving`, the
    // session is destroyed); routing on regardless would resurrect
    // a dead session into home. Bail unless this login is still
    // the live one: stage unchanged and a session token still
    // stored.
    if (!mounted || _stage != _FlowStage.resolving) return;
    try {
      final token = await _sessionStore.readToken();
      if (token == null || token.trim().isEmpty) return;
    } catch (_) {
      return;
    }
    if (!mounted || _stage != _FlowStage.resolving) return;
    if (serverReset) {
      unawaited(_stampFreshAccountOnboarding());
      setState(() {
        _loggedInEmail = email;
        _onboardingStep = OnboardingStep.consent;
        _stage = _FlowStage.onboarding;
      });
    } else {
      unawaited(_markOnboardingComplete());
      setState(() {
        _loggedInEmail = email;
        _stage = _FlowStage.home;
      });
      // TAKEOVER Phase 4 — signing in on a fresh install/update is
      // the other first-run door (see _kickFirstRunResync). The
      // onboarding branch needs no kick: landing home via
      // _onOnboardingComplete kicks it there.
      _kickFirstRunResync();
      // App-open sync: signing in lands home — an app open for
      // this session.
      _triggerAppOpenCapture();
    }
  }

  // TAKEOVER Phase 4 — first-run reminder continuity (Ivy P0 §3.2):
  // scheduled notifications do not survive the package change, and
  // the resync (ReminderSync.syncAll + reconcileReminderAlarms) used
  // to run only when the user opened Settings/Reminders. Run it
  // ONCE per install, in the background, as soon as a session lands
  // home — by cold-start restore or by sign-in. Memoized so the two
  // doors can never double-run it in one process; the persisted
  // done-flag in FirstRunReminderResync makes it once per install,
  // and a failure leaves the flag unstamped so the next launch
  // retries. Never throws into the flow: landing home is never
  // blocked on notification scheduling.
  Future<void>? _firstRunResyncFuture;

  // App-open sync (founder directive, Oct 22, 2026: "we sync every
  // time the app is opened and every 30 minutes in the
  // background"). This flow is the SOLE app-open trigger: it fires
  // on every home landing (cold-start session restore, sign-in,
  // onboarding completion — the _kickFirstRunResync doors) and on
  // every resume while home (see didChangeAppLifecycleState). The
  // other foreground capture callers (Home's snapshot load, the
  // Daily Score history, HealthRepository) deliberately keep the
  // plain throttled capture: in the same open they either join
  // this run in flight through the sync's shared single-flight, or
  // are throttled by the stamp this run leaves — so one open
  // produces exactly ONE capture attempt, never stacked or chained
  // duplicates.
  //
  // FOREGROUND ONLY (Juno ruling, Oct 22, 2026, F1): the trigger
  // fires synchronously while the app is foregrounded and the
  // capture reads in that window; nothing is scheduled for later
  // execution, and the background runner never uses this path.
  // Fire-and-forget: capture never throws, and landing home is
  // never blocked on a sync.
  void _triggerAppOpenCapture() {
    unawaited(HealthHistorySync.instance.captureOnAppOpen());
  }

  void _kickFirstRunResync() {
    _firstRunResyncFuture ??= _runFirstRunResync();
    // Every home landing funnels through here (cold-start restore,
    // sign-in, onboarding completion): a stashed Daily Score
    // notification tap is delivered on the same landing.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _deliverPendingScoreTap());
  }

  Future<void> _runFirstRunResync() async {
    try {
      await FirstRunReminderResync(
        resync: () => performReminderResync(
          backend: _tabsBackend,
          settingsStore: SettingsStore(),
          notifications:
              widget.notificationService ?? LocalReminderNotificationService(),
        ),
      ).runOnce();
    } catch (_) {
      // Unstamped → retried on the next launch. Silent by design:
      // the Settings Notifications page surfaces schedule errors
      // with their codes when the user goes there.
    }
  }

  Future<void> _markOnboardingComplete() async {
    try {
      await _onboardingStore.setHasConsented(true);
      await _onboardingStore.setIntroConsultationSeen(true);
      await _onboardingStore.setOnboardingComplete(true);
    } catch (_) {}
  }

  // Round 32 — real registration succeeded. Native register leaves
  // onboarding incomplete (LoginViewModel.register never sets the
  // flag; onboardingCompleteByServer = false) and MainActivity
  // routes to `consent`. Stamp the fresh-account flags explicitly
  // (all false) so onboarding state EXISTS for this account — that
  // is what lets a later cold start resume onboarding instead of
  // taking the legacy-session home path — then enter the flow at
  // the consent step.
  void _onRegisterSuccess(String email) {
    unawaited(QuickLogCache.instance.clearIfOwnerMismatch(email));
    unawaited(HomeDataCache.instance.clearIfOwnerMismatch(email));
    // R70 fix pass (Vera F1 / Juno C1) — same owner-mismatch
    // enforcement for the historical health store.
    unawaited(HealthHistoryStore.instance.clearIfOwnerMismatch(email));
    // Refresh-scope fix (Oct 20, 2026): same enforcement for the
    // refresh owner's in-memory pending outcomes.
    DailyScoreRefreshOwner.instance.clearIfOwnerMismatch(email);
    // Vera R35 re-review HIGH 2: same owner-mismatch enforcement
    // as login (see _onLoginSuccess).
    unawaited(TodaySummaryCache.instance.clearIfOwnerMismatch(email));
    unawaited(TodayPlanStore.instance.clearIfOwnerMismatch(email));
    unawaited(CoachMemoryStore.instance.clearIfOwnerMismatch(email));
    unawaited(
        KnowledgeExtractionStore.instance.clearIfOwnerMismatch(email));
    unawaited(_stampFreshAccountOnboarding());
    setState(() {
      _loggedInEmail = email;
      _onboardingStep = OnboardingStep.consent;
      _stage = _FlowStage.onboarding;
    });
  }

  Future<void> _stampFreshAccountOnboarding() async {
    try {
      await _onboardingStore.setHasConsented(false);
      await _onboardingStore.setIntroConsultationSeen(false);
      await _onboardingStore.setOnboardingComplete(false);
    } catch (_) {}
  }

  // Round 32 — onboarding finished (setup loading's "Start keeping
  // Tabs"): the completion flag is already written by the setup
  // step (native finalizeSetup); land home.
  void _onOnboardingComplete() {
    setState(() => _stage = _FlowStage.home);
    // TAKEOVER Phase 4 — landing home via a resumed onboarding is
    // also a first-run door (see _kickFirstRunResync).
    _kickFirstRunResync();
    // App-open sync: landing home from onboarding is an app open.
    _triggerAppOpenCapture();
  }

  // Round 32 — consent declined (the decline dialog's "Log Out").
  // Native onDecline: setLoggedIn(false), setHasConsented(false),
  // setIntroConsultationSeen(false), navigate to welcome with the
  // stack cleared. The Flutter session's presence IS the token, so
  // clearing the session is the functional equivalent of
  // setLoggedIn(false); onboardingComplete is left untouched,
  // exactly as native leaves it.
  Future<void> _onConsentDecline() async {
    try {
      await _sessionStore.clear();
    } catch (_) {}
    // Correction round (Juno C2): consent decline ends the session
    // like a logout, and the counter-delete tombstones shared the
    // session-expiry gap on this path too — the same targeted wipe
    // runs here. (The sibling cache clears are expiry-path only,
    // matching native's decline, which likewise leaves them.)
    // Fire-and-forget, exactly like _onSessionExpired: the wipe is
    // best-effort and must never gate the route change on a
    // storage-channel round-trip (the method itself never throws).
    unawaited(SettingsStore().clearDeletedCounterIds());
    try {
      await _onboardingStore.setHasConsented(false);
      await _onboardingStore.setIntroConsultationSeen(false);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _loggedInEmail = null;
      _stage = _FlowStage.welcome;
    });
  }

  @override
  void initState() {
    super.initState();
    // Round 31 — wire the backend's session-expired callback and
    // kick off the cold-start restore (async; never blocks splash).
    _sessionStore = widget.sessionStore ?? SessionStore();
    // Round 32 — the onboarding store the restore gate reads.
    _onboardingStore = widget.onboardingStore ?? OnboardingStore();
    _tabsBackend =
        widget.tabsBackend ?? TabsBackend(sessionStore: _sessionStore);
    TabsBackend.onSessionExpired = _onSessionExpired;
    unawaited(_restoreSession());
    // Daily Score background scoring (founder amendment #2) —
    // register the periodic WorkManager task and arm the
    // score-ready notification tap routing. Both are best-effort
    // and silent: neither may block or break app start.
    unawaited(_initScoreBackground());
    // Takeover Phase 2 — production billing sync triggers (native
    // parity: sync on BillingClient connect + on ON_RESUME). Inert
    // unless the runtime package/flavor gate says this is the
    // production build; the Lab never touches Play Billing.
    WidgetsBinding.instance.addObserver(this);
    unawaited(_startBillingSync());
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _exitMs),
    );
    _exit = CurvedAnimation(
      parent: _exitController,
      curve: Curves.fastOutSlowIn,
    );
    // Entry (650ms) + hold (1200ms), then the native exit sweep.
    Future.delayed(
      const Duration(milliseconds: _entryMs + _holdMs),
      () {
        if (!mounted) return;
        _exitController.forward().whenComplete(() {
          if (mounted) setState(() => _splashVisible = false);
        });
      },
    );
  }

  // ── Daily Score background (founder amendment #2) ──────────────
  //
  // The score-ready notifier this flow owns for tap routing (the
  // background isolate owns its own posting-only instance). A tap
  // carries the scored day as its payload; it opens that day's
  // score detail once the flow is home — a tap that arrives during
  // welcome/login/onboarding is stashed and delivered on the home
  // landing, never dropped and never pushed over the auth flow.
  LocalDailyScoreReadyNotifier? _scoreNotifier;
  String? _pendingScoreTapDate;

  Future<void> _initScoreBackground() async {
    unawaited(DailyScoreBackgroundScheduler.register());
    try {
      _scoreNotifier =
          LocalDailyScoreReadyNotifier(onTap: _onScoreNotificationTap);
      // V-1: initialize() registers the tap handler with the
      // app-level NotificationBootstrap (which owns the plugin's
      // one dispatching callback) and joins its initialization —
      // it does not install a callback of its own.
      await _scoreNotifier!.initialize();
      final launchDate = await _scoreNotifier!.launchScorePayload();
      if (launchDate != null) _onScoreNotificationTap(launchDate);
    } catch (_) {
      // Silent: score notifications are an enhancement; the app
      // must start identically without them.
    }
    // Refresh keep-alive tap (Oct 20, 2026): the cold-start half
    // of the same consumption — a keep-alive notification tap
    // that launched the app left its date with the plugin
    // (MainActivity forwarded the intent extra in onCreate).
    // Consumed here, alongside the score-ready launch payload
    // above, and fed into the SAME tap destination. Best-effort:
    // the wrapper never throws, and no notification plugin is
    // initialized here (the bootstrap owns the one initialize).
    await _consumeKeepAliveTap();
  }

  /// Takes a pending keep-alive notification tap date from the
  /// plugin, if one is held, and routes it exactly like a
  /// score-ready tap: stashed until the flow is home, then the
  /// day's score detail opens (see _onScoreNotificationTap /
  /// _deliverPendingScoreTap).
  Future<void> _consumeKeepAliveTap() async {
    final date = await RefreshKeepAlive.instance.takePendingScoreTap();
    if (date != null) _onScoreNotificationTap(date);
  }

  void _onScoreNotificationTap(String date) {
    _pendingScoreTapDate = date;
    if (_stage == _FlowStage.home) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _deliverPendingScoreTap());
    }
  }

  void _deliverPendingScoreTap() {
    final date = _pendingScoreTapDate;
    if (date == null || !mounted || _stage != _FlowStage.home) return;
    _pendingScoreTapDate = null;
    unawaited(Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DailyScoreDayScreen(
          store: HealthHistoryStore.instance,
          date: date,
        ),
      ),
    ));
  }

  // Takeover Phase 2 — app-lifetime billing sync (start + resume).
  // Null in the Lab and in tests (the production gate fails closed).
  //
  // SINGLE APP-OWNED INSTANCE (Vera takeover review): this flow
  // owns the one BillingService (inside _billingSync) for the
  // app's lifetime. It is threaded to the selling screens via
  // MainShell / OnboardingFlow below — screens consume it, never
  // construct or dispose their own. Ownership ends in this
  // State's dispose(), which disposes _billingSync (and with it
  // the service).
  BillingAppSync? _billingSync;

  Future<void> _startBillingSync() async {
    try {
      final sync = await startBillingAppSync(backend: _tabsBackend);
      if (!mounted) {
        // The flow is already gone: ownership ended before the
        // instance arrived, so dispose it here rather than leak
        // its purchase-updates subscription.
        sync?.dispose();
        return;
      }
      setState(() => _billingSync = sync);
    } catch (_) {
      // Billing must never block or crash app start; the Membership
      // screens surface billing errors visibly when opened.
      _billingSync = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Forward resumes to the billing sync (native ON_RESUME →
    // checkSubscriptionStatus).
    if (state == AppLifecycleState.resumed) {
      _billingSync?.onResumed();
      // App-open sync (founder directive, Oct 22, 2026): a return
      // from background while home is an app open — trigger the
      // open capture NOW, in the foreground (Juno F1), through
      // the shared single-flight. Resumes into welcome / login /
      // onboarding do not capture; those flows capture when they
      // land home.
      if (_stage == _FlowStage.home) _triggerAppOpenCapture();
      // Refresh keep-alive tap, live half: a tap delivered to
      // the running singleTop MainActivity (onNewIntent) while
      // the app was backgrounded is consumed on resume and
      // routed to the same day-detail destination as a
      // score-ready tap.
      unawaited(_consumeKeepAliveTap());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Ownership of the single billing service ends here (see
    // _startBillingSync): this is the only dispose of it.
    _billingSync?.dispose();
    // Round 31 — don't leave this flow's handler registered on the
    // backend after the flow is gone.
    if (TabsBackend.onSessionExpired == _onSessionExpired) {
      TabsBackend.onSessionExpired = null;
    }
    _exitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    return Stack(
      children: [
        if (_stage == _FlowStage.welcome)
          WelcomeScreen(
            onRegister: () => _goLogin(true),
            onLogin: () => _goLogin(false),
          )
        else if (_stage == _FlowStage.login)
          LoginScreen(
            initialRegisterMode: _loginIsRegister,
            onBack: _goWelcome,
            onLoginSuccess: _onLoginSuccess,
            onRegisterSuccess: _onRegisterSuccess,
            authApi: widget.authApi,
            sessionStore: widget.sessionStore,
          )
        else if (_stage == _FlowStage.resolving)
          // Founder fix (Oct 2026) — post-login routing is resolving
          // (see _resolveLoginRoute). A plain loading screen, on
          // purpose: the login form is unmounted so nothing on it
          // (back, a second submit) can race the routing decision.
          const Scaffold(
            backgroundColor: NotelColors.background,
            body: Center(
              child: CircularProgressIndicator(color: NotelColors.primary),
            ),
          )
        else if (_stage == _FlowStage.onboarding)
          OnboardingFlow(
            initialStep: _onboardingStep,
            onboardingStore: _onboardingStore,
            backend: _tabsBackend,
            healthConnectService: widget.healthConnectService,
            notificationService: widget.notificationService,
            billingService: _billingSync?.service,
            onComplete: _onOnboardingComplete,
            onDeclineConsent: () => unawaited(_onConsentDecline()),
          )
        else
          MainShell(email: _loggedInEmail,
              weatherApi: widget.weatherApi,
              locationService: widget.locationService,
              healthConnectService: widget.healthConnectService,
              billingService: _billingSync?.service,
              onLogout: _onLogout),
        if (_splashVisible)
          AnimatedBuilder(
            animation: _exit,
            builder: (context, child) {
              final p = _exit.value;
              // Native spec: alpha holds at 1 through the first 60% of the
              // travel, then fades to 0 over the final 40%.
              final alpha = p < 0.6 ? 1.0 : 1.0 - (p - 0.6) / 0.4;
              return Transform.translate(
                offset: Offset(0, -p * screenHeight),
                child: Opacity(
                  opacity: alpha.clamp(0.0, 1.0),
                  child: child,
                ),
              );
            },
            child: const SplashScreen(),
          ),
      ],
    );
  }
}
