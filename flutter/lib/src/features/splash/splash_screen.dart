import 'package:flutter/material.dart';

/// Round 1 — the opening splash screen.
///
/// Pixel-port of the native app's `SplashScreen.kt` (dark theme, which is the
/// native default). Values taken straight from the Kotlin source:
/// - Background: NotelBackground dark = #080E1A
/// - Logo: ic_tabs_note drawable at 130dp
/// - "Tabs": 36sp, Black, NotelPrimary #7C6EFF, letterSpacing 2sp
/// - Tagline: 14sp, Medium, NotelTextSecondary dark #7A8FAF
/// - Entry: fade 0->1 + scale 0.8->1.05, 650ms, FastOutSlowIn
/// - Hold: 1200ms
///
/// The native splash then slides its content up off-screen into the next
/// route. Round 1 has no next screen yet, so the splash holds visible after
/// the entry animation; the exit transition lands with screen 2.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF080E1A),
      body: Center(
        child: _SplashContent(),
      ),
    );
  }
}

class _SplashContent extends StatefulWidget {
  const _SplashContent();

  @override
  State<_SplashContent> createState() => _SplashContentState();
}

class _SplashContentState extends State<_SplashContent>
    with SingleTickerProviderStateMixin {
  static const _entryDuration = Duration(milliseconds: 650);

  late final AnimationController _controller;
  late final Animation<double> _alpha;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: _entryDuration, vsync: this);
    // FastOutSlowInEasing == Curves.fastOutSlowIn.
    final curved =
        CurvedAnimation(parent: _controller, curve: Curves.fastOutSlowIn);
    _alpha = Tween<double>(begin: 0.0, end: 1.0).animate(curved);
    _scale = Tween<double>(begin: 0.8, end: 1.05).animate(curved);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _alpha.value,
          child: Transform.scale(
            scale: _scale.value,
            child: child,
          ),
        );
      },
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/ic_tabs_note.png',
                width: 130,
                height: 130,
              ),
              const SizedBox(height: 24),
              const Text(
                'Tabs',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF7C6EFF),
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Health & Symptom Intelligence',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF7A8FAF),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
