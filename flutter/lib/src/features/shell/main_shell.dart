import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';

/// Round 9 — the post-login shell: tab state, the bottom nav dock, and
/// placeholder screens.
///
/// - Home tab → the real home screen we've been building (Today header,
///   vitals strip, summary, weekly snapshot).
/// - Tools → the tools grid (round 17, UI only — cards open blank
///   placeholders for now).
/// - Quick-log → the real Quick Log screen (round 19): details field,
///   real categories, AI suggestions, history view.
/// - Heart → the real Heart screen (round 25): native FitbitScreen
///   port (summary, today's pattern chart, spikes, spike review).
/// - Settings → the real Settings screen (round 29): native
///   SettingsScreen port with membership, profile-backed toggles,
///   and real logout / delete-account flows.
/// - The dock stays visible on every tab. The active icon highlights in
///   `NotelPrimary`, matching the native dock's selected state.
/// - The dock is NOT shown on splash / welcome / login — same as native
///   (those stages never reach this shell).
class MainShell extends StatefulWidget {
  final String? email;
  final WeatherApiClient? weatherApi;

  /// Injectable for tests; defaults to the real geolocator wrapper.
  final LocationService? locationService;

  /// Injectable for tests; defaults to a real HealthConnectService.
  final HealthConnectService? healthConnectService;

  /// Round 29 — called by Settings after a completed logout or
  /// account deletion (session + caches already cleared) so the app
  /// returns to the welcome flow.
  final VoidCallback? onLogout;

  const MainShell(
      {super.key,
      this.email,
      this.weatherApi,
      this.locationService,
      this.healthConnectService,
      this.onLogout});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  // Round 19c audit: this single field is the ONLY source of truth
  // for both the body switch below and the dock's `selected:` — they
  // cannot disagree. (The founder-reported wrong highlight lived one
  // level down, in NavDock's pill controller bounds; see nav_dock.dart.)
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
              locationService: widget.locationService,
              healthConnectService: widget.healthConnectService,
            ),
          DockTab.tools => const ToolsScreen(key: ValueKey('tools_screen')),
          DockTab.quickLog => QuickLogScreen(
              key: const ValueKey('quicklog_screen'),
              weatherApi: widget.weatherApi,
            ),
          DockTab.heart => HeartScreen(
              key: const ValueKey('heart_screen'),
              email: widget.email,
              healthConnectService: widget.healthConnectService,
            ),
          DockTab.settings => SettingsScreen(
              key: const ValueKey('settings_screen'),
              email: widget.email,
              onLogout: widget.onLogout,
              healthConnectService: widget.healthConnectService,
            ),
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
