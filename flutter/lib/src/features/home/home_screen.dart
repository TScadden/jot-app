import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

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
class HomeScreen extends StatefulWidget {
  final String? email;
  final WeatherApiClient? weatherApi;

  /// Injectable for tests; defaults to the real geolocator wrapper.
  final LocationService? locationService;

  const HomeScreen(
      {super.key, this.email, this.weatherApi, this.locationService});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int? _temp;
  bool _weatherLoaded = false;

  /// Country code from the IP fetch — reused for units when the user
  /// upgrades to GPS weather via the weather-icon tap.
  String _countryCode = 'US';

  /// Guards against stacked location requests from rapid taps (a stuck
  /// request must never wedge future taps).
  bool _locationRefreshInFlight = false;

  @override
  void initState() {
    super.initState();
    _loadWeather();
  }

  Future<void> _loadWeather() async {
    final reading =
        await (widget.weatherApi ?? WeatherApiClient()).getCurrentWeather();
    if (!mounted) return;
    setState(() {
      _temp = reading.temp;
      _countryCode = reading.countryCode;
      // Loaded only when we have a real reading — a null temp means
      // "unavailable", and the header shows the icon alone.
      _weatherLoaded = reading.temp != null;
    });
  }

  /// Round 10 — weather icon tap: ask for the device location and
  /// upgrade the header temp to GPS-based weather.
  ///
  /// Permission is requested ONLY here (never at startup). Any denial,
  /// disabled services, timeout, or error falls back SILENTLY to the
  /// IP-based fetch — the user never sees an error and the header
  /// never shows a fake reading.
  ///
  /// Privacy: the position is used ONLY to build the Open-Meteo
  /// request below. It is never logged, stored, or sent anywhere
  /// except api.open-meteo.com (HTTPS).
  Future<void> _onWeatherTap() async {
    if (_locationRefreshInFlight) return;
    _locationRefreshInFlight = true;
    try {
      final location = widget.locationService ?? LocationService();

      // Location services off → IP fallback, silently.
      if (!await location.isServiceEnabled()) {
        await _loadWeather();
        return;
      }

      var permission = await location.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await location.requestPermission();
      }
      // Denied (including permanently) → IP fallback, silently. Never
      // nag, never error.
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        await _loadWeather();
        return;
      }

      final position = await location.getPosition();
      // No fix (timeout etc.) → IP fallback, silently.
      if (position == null) {
        await _loadWeather();
        return;
      }

      final temp = await (widget.weatherApi ?? WeatherApiClient())
          .getCurrentTempAt(
        latitude: position.latitude,
        longitude: position.longitude,
        countryCode: _countryCode,
      );
      if (!mounted) return;
      setState(() {
        _temp = temp;
        _weatherLoaded = temp != null;
      });
    } catch (_) {
      // Anything unexpected: fall back to the IP fetch rather than
      // surfacing an error.
      await _loadWeather();
    } finally {
      _locationRefreshInFlight = false;
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
                    Icon(
                      Icons.cloud,
                      size: 20,
                      color: NotelColors.primary.withValues(alpha: 0.7),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Watch: native navigates to the data-connections screen —
          // that screen doesn't exist yet, so this is a no-op for now.
          IconButton(
            onPressed: () {},
            icon: const Icon(
              Icons.watch,
              size: 24,
              color: NotelColors.primary,
            ),
            tooltip: 'Connections',
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const VitalsStrip(),
            const HomeStreakRow(),
            const TodaySummaryCard(),
            const WeeklySnapshotCard(),
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
