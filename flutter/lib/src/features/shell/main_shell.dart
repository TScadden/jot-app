import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 9 — the post-login shell: tab state, the bottom nav dock, and
/// placeholder screens.
///
/// - Home tab → the real home screen we've been building (Today header,
///   vitals strip, summary, weekly snapshot).
/// - Tools, quick-log, Heart, Settings → blank navy placeholders for now;
///   their real screens land in future rounds. The founder's directive:
///   "they should just go to a blank screen."
/// - The dock stays visible on every tab. The active icon highlights in
///   `NotelPrimary`, matching the native dock's selected state.
/// - The dock is NOT shown on splash / welcome / login — same as native
///   (those stages never reach this shell).
class MainShell extends StatefulWidget {
  final String? email;
  final WeatherApiClient? weatherApi;

  const MainShell({super.key, this.email, this.weatherApi});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  DockTab _tab = DockTab.home;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Tab body. Tapping the active tab is a no-op (native parity).
        switch (_tab) {
          DockTab.home => HomeScreen(
              email: widget.email,
              weatherApi: widget.weatherApi,
            ),
          DockTab.tools => const _BlankTab(key: ValueKey('blank_tools')),
          DockTab.quickLog =>
            const _BlankTab(key: ValueKey('blank_quicklog')),
          DockTab.heart => const _BlankTab(key: ValueKey('blank_heart')),
          DockTab.settings =>
            const _BlankTab(key: ValueKey('blank_settings')),
        },
        // Dock floats above every tab.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: NavDock(
            selected: _tab,
            onSelect: (tab) {
              if (tab != _tab) setState(() => _tab = tab);
            },
          ),
        ),
      ],
    );
  }
}

/// Blank placeholder tab: empty navy background, no content.
/// Replaced by the real screen in a future round.
class _BlankTab extends StatelessWidget {
  const _BlankTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: NotelColors.background,
    );
  }
}
