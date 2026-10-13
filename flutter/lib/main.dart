import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_flow.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/splash/splash_screen.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';

void main() async {
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
  await HomeDataCache.instance.warmFromDisk(currentEmail: sessionEmail);
  // Round 19c — same warm for Quick Log: cold starts seed last-known
  // categories / recents / count / membership instead of skeletons.
  await QuickLogCache.instance.warmFromDisk(currentEmail: sessionEmail);
  runApp(const TabsLabApp());
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

enum _FlowStage { welcome, login, onboarding, home }

class _AppFlowState extends State<AppFlow> with SingleTickerProviderStateMixin {
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
  Future<void> _restoreSession() async {
    try {
      final token = await _sessionStore.readToken();
      if (token == null || token.trim().isEmpty) return;
      // Round 31 fix pass (Vera NIT 2): the email read is isolated
      // in its own try/catch. The email is display-only — a storage
      // failure reading it must not abort a restore backed by a
      // valid token, so route on with a null email. A TOKEN-read
      // failure keeps the outer behavior: fall to welcome, without
      // clearing anything.
      String? email;
      try {
        email = await _sessionStore.readEmail();
      } catch (_) {
        email = null;
      }
      // Round 32 gate: resolve the native resume step from the
      // stored flags (local reads only — same store, no network).
      OnboardingStep? resumeStep;
      var hasState = false;
      try {
        hasState = await _onboardingStore.hasAnyState();
        if (hasState) {
          final hasConsented = await _onboardingStore.getHasConsented();
          final introSeen =
              await _onboardingStore.getIntroConsultationSeen();
          final complete = await _onboardingStore.getOnboardingComplete();
          if (!hasConsented) {
            resumeStep = OnboardingStep.consent;
          } else if (!introSeen) {
            resumeStep = OnboardingStep.consultationIntro;
          } else if (!complete) {
            resumeStep = OnboardingStep.profileSetup;
          }
        }
      } catch (_) {
        // Unreadable flags → Round 31 behavior (home).
        resumeStep = null;
        hasState = false;
      }
      // If the user already moved past welcome (or the widget is
      // gone), the restore has nothing to do.
      if (!mounted || _stage != _FlowStage.welcome) return;
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
          _onboardingStep = resumeStep!;
          _stage = _FlowStage.onboarding;
        });
      } else {
        setState(() {
          _loggedInEmail = email;
          _stage = _FlowStage.home;
        });
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
    // Vera R35 re-review HIGH 2: the Today Summary stores are
    // account-bound too — a session expiry must leave none of the
    // expired account's summary on device (R29b standard). Each
    // clear is independently best-effort, like the two above.
    unawaited(TodaySummaryCache.instance.clear());
    unawaited(TodayPlanStore.instance.clear());
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
    // Vera R35 re-review HIGH 2: the Round 35 Today Summary stores
    // join the same owner-mismatch enforcement — a previous
    // account's cached summary / plan state must be gone before
    // the shell mounts for the new account.
    unawaited(TodaySummaryCache.instance.clearIfOwnerMismatch(email));
    unawaited(TodayPlanStore.instance.clearIfOwnerMismatch(email));
    // Round 32 — native parity: email login and Google sign-in (both
    // modes) mark onboarding complete (LoginViewModel.login /
    // loginWithGoogleAccount call setOnboardingComplete(true)), and
    // MainActivity's onLoginSuccess(true) branch also sets
    // hasConsented + introConsultationSeen before navigating home.
    unawaited(_markOnboardingComplete());
    setState(() {
      _loggedInEmail = email;
      _stage = _FlowStage.home;
    });
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
    // Vera R35 re-review HIGH 2: same owner-mismatch enforcement
    // as login (see _onLoginSuccess).
    unawaited(TodaySummaryCache.instance.clearIfOwnerMismatch(email));
    unawaited(TodayPlanStore.instance.clearIfOwnerMismatch(email));
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

  @override
  void dispose() {
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
        else if (_stage == _FlowStage.onboarding)
          OnboardingFlow(
            initialStep: _onboardingStep,
            onboardingStore: _onboardingStore,
            backend: _tabsBackend,
            healthConnectService: widget.healthConnectService,
            notificationService: widget.notificationService,
            onComplete: _onOnboardingComplete,
            onDeclineConsent: () => unawaited(_onConsentDecline()),
          )
        else
          MainShell(email: _loggedInEmail,
              weatherApi: widget.weatherApi,
              locationService: widget.locationService,
              healthConnectService: widget.healthConnectService,
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
