import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
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

  const AppFlow(
      {super.key,
      this.authApi,
      this.sessionStore,
      this.weatherApi,
      this.locationService,
      this.healthConnectService});

  @override
  State<AppFlow> createState() => _AppFlowState();
}

enum _FlowStage { welcome, login, home }

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
  void _onLogout() {
    setState(() {
      _loggedInEmail = null;
      _stage = _FlowStage.welcome;
    });
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
    setState(() {
      _loggedInEmail = email;
      _stage = _FlowStage.home;
    });
  }

  @override
  void initState() {
    super.initState();
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
            authApi: widget.authApi,
            sessionStore: widget.sessionStore,
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
