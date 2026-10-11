import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 4 — home screen, background only.
///
/// Matches the native `today` route (`TodayScreen.kt`): the Scaffold's
/// container color is `NotelBackground` (#080E1A, flat — no gradients,
/// no scrims). Per the founder's directive, no dock, no tiles, no cards,
/// no header, no content yet — features land in later rounds once login
/// is real.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: NotelColors.background,
      body: SizedBox.expand(),
    );
  }
}
