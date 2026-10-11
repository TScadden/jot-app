import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/splash/splash_screen.dart';

void main() {
  runApp(const TabsLabApp());
}

class TabsLabApp extends StatelessWidget {
  const TabsLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Tabs Lab',
      debugShowCheckedModeBanner: false,
      home: AppFlow(),
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

  const AppFlow(
      {super.key, this.authApi, this.sessionStore, this.weatherApi});

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

  // Round 5: real login succeeded — the session is already in secure
  // storage (LoginScreen handles that); record the email for the home
  // indicator and navigate.
  void _onLoginSuccess(String email) {
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
          HomeScreen(email: _loggedInEmail, weatherApi: widget.weatherApi),
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
