import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tabs_lab/src/data/location_service.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/weather_info_sheets.dart';
import 'package:tabs_lab/src/features/home/weather_info_sheets2.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 11 — weather detail bottom sheet.
///
/// Faithful port of the native `ModalBottomSheet` in `TodayScreen.kt`
/// (the `showWeatherSheet` block): rationale card, loading skeletons,
/// honest unavailable state, and the 5-row detail card. All values come
/// from [WeatherApiClient.getDetailedWeather]; missing fields render
/// as "--", never zeros.
///
/// Tapping a row opens that metric's info sheet (native `showTempInfo`
/// etc.), ported with the native static copy.
///
/// MF-1 (Juno compliance, Oct 2026): the sheet is the ONLY place that may
/// trigger the system location dialog, and only from the rationale card's
/// "Share location" button. A grant there is reported back through
/// [onLocationGranted] so the caller can refresh its own location UI.
Future<void> showWeatherSheet({
  required BuildContext context,
  required WeatherApiClient weatherApi,
  required LocationService locationService,
  Future<Position?>? gpsPositionFuture,
  ValueChanged<Position>? onLocationGranted,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => _WeatherSheet(
      weatherApi: weatherApi,
      locationService: locationService,
      gpsPositionFuture: gpsPositionFuture,
      onLocationGranted: onLocationGranted,
    ),
  );
}

class _WeatherSheet extends StatefulWidget {
  final WeatherApiClient weatherApi;
  final LocationService locationService;
  final Future<Position?>? gpsPositionFuture;
  final ValueChanged<Position>? onLocationGranted;

  const _WeatherSheet({
    required this.weatherApi,
    required this.locationService,
    this.gpsPositionFuture,
    this.onLocationGranted,
  });

  @override
  State<_WeatherSheet> createState() => _WeatherSheetState();
}

class _WeatherSheetState extends State<_WeatherSheet> {
  bool _loading = true;
  WeatherDetails? _details;
  bool _showRationale = false;
  bool _rationaleDismissed = false;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _refreshRationale();
    _load();
  }

  Future<void> _refreshRationale() async {
    try {
      final permission = await widget.locationService.checkPermission();
      if (!mounted || _rationaleDismissed) return;
      setState(() {
        _showRationale = permission != LocationPermission.whileInUse &&
            permission != LocationPermission.always;
      });
    } catch (_) {
      // Permission check failed: leave the rationale hidden; the sheet
      // still loads IP-based weather.
    }
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _details = null;
    });
    try {
      Position? position;
      final gpsFuture = widget.gpsPositionFuture;
      if (gpsFuture != null) {
        position = await gpsFuture.timeout(
          const Duration(seconds: 15),
          onTimeout: () => null,
        );
      }
      final WeatherDetails? details;
      if (position != null) {
        details = await widget.weatherApi.getDetailedWeather(
          manualLat: position.latitude,
          manualLon: position.longitude,
          manualCity: 'Current Location',
        );
      } else {
        details = await widget.weatherApi.getDetailedWeather();
      }
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _details = details;
      });
      // Re-check the rationale in case permission changed while the sheet
      // was open (e.g. granted in system settings); a fresh grant hides
      // the rationale card. The sheet itself is the only place that may
      // trigger the system dialog (MF-1).
      _refreshRationale();
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _details = null;
      });
    }
  }

  Future<void> _onShareLocation() async {
    try {
      final permission = await widget.locationService.requestPermission();
      if (!mounted) return;
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        setState(() => _showRationale = false);
        // MF-1: this is the SOLE system-dialog trigger in the app. Report
        // the granted position so the caller can refresh its location UI.
        final position = await _loadWithGps();
        if (position != null) widget.onLocationGranted?.call(position);
      }
      // Denied: rationale stays; the sheet keeps IP-based weather.
    } catch (_) {
      // Silently keep the current state.
    }
  }

  Future<Position?> _loadWithGps() async {
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _details = null;
    });
    try {
      final position = await widget.locationService.getPosition();
      final WeatherDetails? details;
      if (position != null) {
        details = await widget.weatherApi.getDetailedWeather(
          manualLat: position.latitude,
          manualLon: position.longitude,
          manualCity: 'Current Location',
        );
      } else {
        details = await widget.weatherApi.getDetailedWeather();
      }
      if (!mounted || token != _loadToken) return null;
      setState(() {
        _loading = false;
        _details = details;
      });
      return position;
    } catch (_) {
      if (!mounted || token != _loadToken) return null;
      setState(() {
        _loading = false;
        _details = null;
      });
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 64.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (_showRationale && !_rationaleDismissed) ...[
                  _LocationRationaleCard(
                    onShareLocation: _onShareLocation,
                    onDismiss: () =>
                        setState(() => _rationaleDismissed = true),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_loading)
                  _buildLoading()
                else if (_details == null || !_details!.loaded)
                  _buildUnavailable()
                else
                  _buildLoaded(_details!),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < 5; i++) ...[
          const _WeatherSkeletonRow(),
          if (i < 4)
            const Divider(
              color: Color(0x66152040),
              thickness: 0.5,
              height: 0.5,
            ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Fetching local weather...',
          style: TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildUnavailable() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('☁️', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 16),
          const Text(
            "Couldn't load weather right now",
            style: TextStyle(
              color: NotelColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Weather needs a connection and your location to load. '
            'Check your connection and try again.',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _load,
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text(
              'Try again',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoaded(WeatherDetails weather) {
    final uvHigh = (weather.uvIndex ?? 0) > 5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          weather.locationName ?? 'Unknown',
          style: const TextStyle(
            color: NotelColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          weather.condition ?? '',
          style: const TextStyle(
            color: NotelColors.textSecondary,
            fontSize: 13,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              _WeatherInfoRow(
                emoji: weather.iconEmoji ?? '☁️',
                title: 'Temperature',
                hint: 'Tap to see optimal temperature ranges',
                value: weather.temp == null
                    ? '--'
                    : '${weather.temp}°${weather.unit}',
                onTap: () => showTempInfoSheet(context),
              ),
              _rowDivider(),
              _WeatherInfoRow(
                emoji: '💧',
                title: 'Humidity',
                hint: 'Tap to see comfort levels & hydration guidance',
                value: weather.humidity == null
                    ? '--'
                    : '${weather.humidity}%',
                onTap: () => showHumidityInfoSheet(context),
              ),
              _rowDivider(),
              _WeatherInfoRow(
                emoji: '💨',
                title: 'Wind Velocity',
                hint: 'Tap to see wind chill & training impact',
                value: _windValue(weather),
                valueSuffix: weather.windSpeed == null
                    ? null
                    : (weather.unit == 'F' ? 'mph' : 'km/h'),
                onTap: () => showWindInfoSheet(context),
              ),
              _rowDivider(),
              _WeatherInfoRow(
                emoji: '☀️',
                title: 'UV Index',
                hint: 'Tap to see safe exposure times',
                value: weather.uvIndex == null
                    ? '--'
                    : weather.uvIndex!.toStringAsFixed(1),
                titleColor:
                    uvHigh ? NotelColors.primary : NotelColors.textPrimary,
                valueColor:
                    uvHigh ? NotelColors.primary : NotelColors.textPrimary,
                emojiColor:
                    uvHigh ? NotelColors.primary : NotelColors.textPrimary,
                badge: uvHigh ? 'High risk' : null,
                onTap: () => showUvInfoSheet(context),
              ),
              _rowDivider(),
              _WeatherInfoRow(
                emoji: '⏲️',
                title: 'Barometric Pressure',
                hint: 'Tap to see joint pain & migraine triggers',
                value: weather.pressure == null
                    ? '--'
                    : weather.pressure!.toStringAsFixed(0),
                valueSuffix:
                    weather.pressure == null ? null : 'hPa',
                onTap: () => showPressureInfoSheet(context),
              ),
            ],
          ),
        ),
        if (uvHigh) ...[
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: NotelColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: NotelColors.primary.withValues(alpha: 0.3),
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: const Row(
              children: [
                Icon(
                  Icons.warning,
                  color: NotelColors.primary,
                  size: 16,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'High UV levels detected. Consider sun protection.',
                    style: TextStyle(
                      color: NotelColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  String _windValue(WeatherDetails weather) {
    if (weather.windSpeed == null) return '--';
    return weather.windSpeed!.toStringAsFixed(1);
  }

  Widget _rowDivider() {
    return const Divider(
      color: Color(0x66152040),
      thickness: 0.5,
      height: 0.5,
    );
  }
}

/// Native `LocationRationaleCard` — verbatim copy and actions.
class _LocationRationaleCard extends StatelessWidget {
  final VoidCallback onShareLocation;
  final VoidCallback onDismiss;

  const _LocationRationaleCard({
    required this.onShareLocation,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Text('📍', style: TextStyle(fontSize: 24)),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Use your location for weather?',
                  style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Share your approximate location so weather reflects where you '
            'actually are instead of guessing from your network. You can '
            'change this anytime in Settings.',
            style: TextStyle(
              color: NotelColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: onShareLocation,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NotelColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text(
                    'Share location',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextButton(
                  onPressed: onDismiss,
                  child: const Text(
                    'Not now',
                    style: TextStyle(
                      color: NotelColors.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Skeleton mirror of one weather-card row (native `WeatherSkeletonRow`).
class _WeatherSkeletonRow extends StatelessWidget {
  const _WeatherSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        children: [
          _skeletonBox(24, 24, 6),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _skeletonFraction(0.55, 14),
                const SizedBox(height: 4),
                _skeletonFraction(0.8, 11),
              ],
            ),
          ),
          _skeletonBox(48, 15, 4),
        ],
      ),
    );
  }

  Widget _skeletonBox(double w, double h, double r) {
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: NotelColors.textSecondary.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(r),
      ),
    );
  }

  Widget _skeletonFraction(double fraction, double h) {
    return FractionallySizedBox(
      widthFactor: fraction,
      child: Container(
        height: h,
        decoration: BoxDecoration(
          color: NotelColors.textSecondary.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

/// One tappable row of the weather detail card (native row pattern).
class _WeatherInfoRow extends StatelessWidget {
  final String emoji;
  final String title;
  final String hint;
  final String value;
  final String? valueSuffix;
  final Color? titleColor;
  final Color? valueColor;
  final Color? emojiColor;
  final String? badge;
  final VoidCallback onTap;

  const _WeatherInfoRow({
    required this.emoji,
    required this.title,
    required this.hint,
    required this.value,
    this.valueSuffix,
    this.titleColor,
    this.valueColor,
    this.emojiColor,
    this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0),
        child: Row(
          children: [
            Text(
              emoji,
              style: TextStyle(
                fontSize: 24,
                color: emojiColor,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: titleColor ?? NotelColors.textPrimary,
                            fontWeight: FontWeight.w500,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: NotelColors.primary
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            badge!,
                            style: const TextStyle(
                              color: NotelColors.primary,
                              fontSize: 8,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    hint,
                    style: const TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: valueColor ?? NotelColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (valueSuffix != null) ...[
                  const SizedBox(width: 2),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: Text(
                      valueSuffix!,
                      style: const TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: NotelColors.textSecondary.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}
