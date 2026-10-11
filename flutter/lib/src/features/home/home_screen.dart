import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 4 — home screen, background only.
///
/// Matches the native `today` route (`TodayScreen.kt`): the Scaffold's
/// container color is `NotelBackground` (#080E1A, flat — no gradients,
/// no scrims). Per the founder's directive, no dock, no tiles, no cards,
/// no header, no content yet — features land in later rounds once login
/// is real.
///
/// Round 5: after a real login, shows a small centered
/// "Logged in as {email}" indicator. TEMPORARY — it exists only so the
/// founder can verify login worked; it goes away when real home content
/// lands.
class HomeScreen extends StatelessWidget {
  final String? email;

  const HomeScreen({super.key, this.email});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      body: SizedBox.expand(
        child: email == null
            ? null
            : Center(
                child: Text(
                  'Logged in as $email',
                  style: const TextStyle(
                    fontSize: 14,
                    color: NotelColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
      ),
    );
  }
}
