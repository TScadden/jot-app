import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
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

/// Round 2 app flow: splash entry (650ms) -> hold (1200ms) -> native-spec
/// exit (650ms slide-up, FastOutSlowIn, alpha holding through the first 60%
/// of travel then fading) revealing the login screen underneath.
///
/// The welcome_onboarding screen does not exist yet; it will slot in
/// between splash and login in a later round.
class AppFlow extends StatefulWidget {
  const AppFlow({super.key});

  @override
  State<AppFlow> createState() => _AppFlowState();
}

class _AppFlowState extends State<AppFlow> with SingleTickerProviderStateMixin {
  static const _entryMs = 650;
  static const _holdMs = 1200;
  static const _exitMs = 650;

  late final AnimationController _exitController;
  late final Animation<double> _exit;
  bool _splashVisible = true;

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
        const LoginScreen(),
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
