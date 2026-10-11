import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/home/weather_sheet.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Round 4 — home screen, background only (native `today` route).
///
/// Round 5: after a real login, shows a small centered
/// "Logged in as {email}" indicator. TEMPORARY — it exists only so the
/// founder can verify login worked; it goes away when real home content
/// lands.
///
/// Round 6 — Today header (native `TodayScreen.kt` topBar):
/// - AppBar, container `NotelBackground`, title "Today" (22sp Black,
///   `NotelTextPrimary`), no navigation icon.
/// - Weather action (64dp wide): `"{temp}°"` (14sp Bold, textPrimary 80%)
///   + cloud icon (20dp, primary 70%). The temp renders ONLY when real
///   data has loaded — never placeholder zeros; icon alone until then.
///   Tap is a no-op for now (the native weather sheet doesn't exist yet).
/// - Watch action: watch icon (24dp, `NotelPrimary`). Native calls
///   `onNavigateToConnections` here; that screen doesn't exist yet, so
///   the tap is a no-op for now.
/// Round 8 — Today Summary + Weekly Snapshot cards sit under the streak
/// row (native `TodayScreen.kt` items 3 and 3B). Data sources aren't wired
/// yet, so both cards show their native empty states; the snapshot metric
/// switcher is live across all 7 metrics. The "Logged in as" indicator
/// stays below them until real home content lands.
/// Round 10 — tapping the weather icon asks for the device location
/// (system permission dialog) and upgrades the IP-based temp to a
/// GPS-based one. Denial or disabled services fall back silently to
/// the IP fetch — never an error, never a fake zero.
/// Round 12 — the watch icon opens the data-connections screen
/// (Health Connect permission flow + retired-Fitbit notice).
class HomeScreen extends StatefulWidget {
  final String? email;
  final WeatherApiClient? weatherApi;

  /// Injectable for tests; defaults to the real geolocator wrapper.
  final LocationService? locationService;

  /// Injectable for tests; defaults to a real HealthConnectService.
  /// Shared with the connections screen (and future onboarding) — state
  /// is persisted, so any instance sees the same connection.
  final HealthConnectService? healthConnectService;

  const HomeScreen(
      {super.key,
      this.email,
      this.weatherApi,
      this.locationService,
      this.healthConnectService});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int? _temp;
  bool _weatherLoaded = false;

  /// Round 14 — condition fields for the living header icon.
  int? _weatherCode;
  bool _isDay = true;

  /// Country code from the IP fetch — reused for units when the user
  /// upgrades to GPS weather via the weather-icon tap.
  String _countryCode = 'US';

  // ── Round 13: real health data ──────────────────────────────────────────
  late final HealthRepository _healthRepo;
  TodayVitals? _vitals;
  int? _currentStreak;
  int? _bestStreak;

  @override
  void initState() {
    super.initState();
    _healthRepo = HealthRepository(
      hc: widget.healthConnectService ?? HealthConnectService(),
    );
    _loadWeather();
    _loadHealthData();
  }

  /// Loads today's vitals + streaks once at startup. Everything is
  /// honest-empty on failure: the repository never throws, and any
  /// individual piece simply stays null/"--".
  Future<void> _loadHealthData() async {
    final hc = _healthRepo.hc;
    bool connected = false;
    try {
      connected = await hc.isConnected();
    } catch (_) {
      connected = false;
    }
    final vitals = await _healthRepo.loadTodayVitals(connected: connected);
    final streak = await _healthRepo.loadStreak();
    if (!mounted) return;
    setState(() {
      _vitals = vitals;
      _currentStreak = streak.current;
      _bestStreak = streak.best;
    });
  }

  Future<void> _loadWeather() async {
    final reading =
        await (widget.weatherApi ?? WeatherApiClient())
            .getCurrentWeatherCondition();
    if (!mounted) return;
    setState(() {
      _temp = reading.temp;
      _countryCode = reading.countryCode;
      _weatherCode = reading.weatherCode;
      _isDay = reading.isDay;
      // Loaded only when we have a real reading — a null temp means
      // "unavailable", and the header shows the icon alone.
      _weatherLoaded = reading.temp != null;
    });
  }

  /// MF-1 (Juno compliance, Oct 2026): the weather tap NEVER requests
  /// location permission — it only *checks* the current status.
  /// - Already granted → fetch the GPS position silently (no system
  ///   dialog can appear) and share it with the sheet; the header temp
  ///   upgrades in the background.
  /// - Not granted → the sheet opens with the in-app rationale card, and
  ///   only the card's "Share location" button may trigger the system
  ///   dialog. A grant there upgrades the header temp via
  ///   [showWeatherSheet]'s onLocationGranted.
  /// Any denial, disabled services, timeout, or error falls back SILENTLY
  /// to the IP-based fetch — the user never sees an error and the header
  /// never shows a fake reading. (Play prominent-disclosure rule: the
  /// in-app rationale must precede the system dialog.)
  ///
  /// Privacy: the position is used ONLY to build the Open-Meteo
  /// request below. It is never logged, stored, or sent anywhere
  /// except api.open-meteo.com (HTTPS).
  Future<void> _onWeatherTap() async {
    final location = widget.locationService ?? LocationService();
    Future<Position?>? gpsFuture;
    try {
      final permission = await location.checkPermission();
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        gpsFuture = location.getPosition();
        // Upgrade the header temp in the background; any failure keeps
        // the IP-based reading silently.
        gpsFuture.then((position) {
          if (position != null && mounted) _upgradeHeaderCondition(position);
        });
      }
    } catch (_) {
      gpsFuture = null;
    }
    if (!mounted) return;
    await showWeatherSheet(
      context: context,
      weatherApi: widget.weatherApi ?? WeatherApiClient(),
      locationService: location,
      gpsPositionFuture: gpsFuture,
      onLocationGranted: (position) {
        if (mounted) _upgradeHeaderCondition(position);
      },
    );
  }

  /// Fetches the current conditions at [position] and upgrades the
  /// header (temp + living icon). Silent on any failure — the IP-based
  /// reading stays.
  Future<void> _upgradeHeaderCondition(Position position) async {
    try {
      final condition = await (widget.weatherApi ?? WeatherApiClient())
          .getConditionAt(
        latitude: position.latitude,
        longitude: position.longitude,
        countryCode: _countryCode,
      );
      if (!mounted) return;
      setState(() {
        _temp = condition.temp;
        _weatherCode = condition.weatherCode;
        _isDay = condition.isDay;
        _weatherLoaded = condition.temp != null;
      });
    } catch (_) {
      // Keep the IP-based reading.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text(
          'Today',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          // Weather: tap asks for device location (system dialog) and
          // upgrades the IP-based temp to GPS-based weather. Denial
          // falls back silently to the IP fetch.
          SizedBox(
            width: 64,
            child: IconButton(
              onPressed: _onWeatherTap,
              padding: EdgeInsets.zero,
              icon: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_weatherLoaded)
                      Text(
                        '${_temp!}°',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color:
                              NotelColors.textPrimary.withValues(alpha: 0.8),
                        ),
                      ),
                    if (_weatherLoaded) const SizedBox(width: 4),
                    // Round 14 — the condition icon is alive: rotating sun
                    // rays, falling rain, drifting clouds, twinkling stars.
                    // Before any condition loads it renders a static cloud
                    // (the old icon's "no data yet" role).
                    AnimatedWeatherIcon(
                      weatherCode: _weatherCode,
                      isDay: _isDay,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Watch: opens the data-connections screen (native
          // onNavigateToConnections). Round 12b: explicit slide-in-from-right —
          // Material 3's default Android transition is a zoom/fade that reads
          // as "just spawning in". Round 14: the icon is a shared element —
          // it flies to the connections screen's back arrow during the push
          // (skipped under reduced motion, where heroes are omitted).
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                SlidePageRoute(
                  builder: (_) => ConnectionsScreen(
                    healthConnectService: widget.healthConnectService,
                  ),
                ),
              );
            },
            icon: animationsDisabled(context)
                ? const Icon(
                    Icons.watch,
                    size: 24,
                    color: NotelColors.primary,
                  )
                : const Hero(
                    tag: watchConnectionsHeroTag,
                    child: Icon(
                      Icons.watch,
                      size: 24,
                      color: NotelColors.primary,
                    ),
                  ),
            tooltip: 'Connections',
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Round 14 — staggered entrance: the cards cascade in with a
            // fade + slight rise, ~80ms apart. Purely visual; data loads
            // independently underneath.
            StaggeredEntrance(
              index: 0,
              child: VitalsStrip(vitals: _vitals),
            ),
            StaggeredEntrance(
              index: 1,
              child: HomeStreakRow(
                currentStreak: _currentStreak,
                bestStreak: _bestStreak,
              ),
            ),
            const StaggeredEntrance(
              index: 2,
              child: TodaySummaryCard(),
            ),
            StaggeredEntrance(
              index: 3,
              child: WeeklySnapshotCard(
                loadData: (metric) => _healthRepo.loadSnapshot(metric),
              ),
            ),
            if (widget.email != null)
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(
                  'Logged in as ${widget.email}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: NotelColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            // Clearance so the last content never hides behind the
            // floating nav dock (dock ≈ 56dp + 12dp + nav inset).
            const SizedBox(height: 110),
          ],
        ),
      ),
    );
  }
}
