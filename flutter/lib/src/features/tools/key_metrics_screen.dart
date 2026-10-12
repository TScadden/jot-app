import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 (Team C) — Key Metrics, Flutter port of the native
/// `KeyMetricsScreen.kt` metric-card layout (2-column `MetricTile` grid).
///
/// Data sources:
/// - sync-pull `profile` (`todayAvgHr`, `weightKg`, …)
/// - Health Connect via `isConnected()` gate: 7-day resting-HR history
///   and active-calories history (native channel calls wrapped in
///   try/catch; a missing/failed channel yields honest "No Data Recorded").
///
/// Founder's data rules: a biometric 0 is a failed read (never charted),
/// heart rate is the daytime 7am–11pm number wherever shown, missing
/// values render as "--"/"No Data Recorded", never invented.
///
/// Deferred (reported to parent): per-day historical tiles, the date
/// picker, and CSV export — those live on the native Fitbit pipeline
/// (spike math) and have no Flutter equivalent on this branch.
class KeyMetricsScreen extends StatefulWidget {
  final TabsBackend? backend;
  final HealthConnectService? healthConnect;

  const KeyMetricsScreen({super.key, this.backend, this.healthConnect});

  @override
  State<KeyMetricsScreen> createState() => _KeyMetricsScreenState();
}

class _MetricsData {
  final int? avgHr;
  final double? weightLbs;
  final int? restingHr;
  final int? activeCalories;
  final bool hcConnected;

  const _MetricsData({
    this.avgHr,
    this.weightLbs,
    this.restingHr,
    this.activeCalories,
    this.hcConnected = false,
  });
}

class _KeyMetricsScreenState extends State<KeyMetricsScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();
  HealthConnectService get _hc =>
      widget.healthConnect ?? HealthConnectService();

  bool _loading = true;
  _MetricsData _data = const _MetricsData();
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    int? avgHr;
    double? weightLbs;
    int? restingHr;
    int? calories;
    var hcConnected = false;
    String? error;

    try {
      final profile = await _backend.fetchProfile();
      if (profile == null) {
        error = 'Could not load your metrics. Check your connection and try again.';
      } else {
        avgHr = nonZeroInt(profile['todayAvgHr']);
        final kg = profile['weightKg'];
        if (kg is num && kg > 0) weightLbs = kg * 2.20462;
      }
    } catch (_) {
      error = 'Could not load your metrics. Check your connection and try again.';
    }

    try {
      // Guarded with a timeout: a stuck channel (see team LESSONS.md —
      // "stuck permission requests" / silent channel failures) must never
      // wedge the whole screen on a spinner.
      hcConnected = await _guarded(() => _hc.isConnected()) ?? false;
    } catch (_) {
      // Missing channel / unavailable Health Connect → honest empty.
      hcConnected = false;
    }

    if (hcConnected) {
      final today = _dateStr(DateTime.now());
      try {
        final hrHistory =
            await _guarded(() => _hc.readRestingHrHistory(7)) ?? const [];
        final todayRow = hrHistory.where((r) => r.date == today && r.bpm > 0);
        if (todayRow.isNotEmpty) {
          restingHr = todayRow.last.bpm;
        } else {
          final any = hrHistory.where((r) => r.bpm > 0);
          if (any.isNotEmpty) restingHr = any.last.bpm;
        }
      } catch (_) {
        // keep null — honest empty
      }
      try {
        final calHistory =
            await _guarded(() => _hc.readCaloriesHistory(7)) ?? const [];
        final todayRow = calHistory.where((r) => r.date == today && r.kcal > 0);
        if (todayRow.isNotEmpty) calories = todayRow.last.kcal;
      } catch (_) {
        // keep null — honest empty
      }
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
      _data = _MetricsData(
        avgHr: avgHr,
        weightLbs: weightLbs,
        restingHr: restingHr,
        activeCalories: calories,
        hcConnected: hcConnected,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: NotelColors.textSecondary, semanticLabel: 'Back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Key Metrics',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: NotelColors.textPrimary),
            ),
            Text(
              formatMetricDate(DateTime.now()),
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.primary),
            ),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: NotelColors.primary));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 56, color: NotelColors.textSecondary),
              const SizedBox(height: 16),
              Text(_error!,
                  style: const TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: NotelColors.textSecondary),
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() => _loading = true);
                  _load();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final d = _data;
    return GridView.count(
      crossAxisCount: 2,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 0.78,
      children: [
        MetricTile(
          title: 'Heart Rate',
          value: d.avgHr == null ? null : '${d.avgHr}',
          unit: 'BPM',
          icon: Icons.favorite,
          color: NotelColors.primary,
          isLoading: false,
          subtitle: 'Daytime average (7am–11pm)',
        ),
        MetricTile(
          title: 'Weight',
          value: d.weightLbs == null ? null : '${d.weightLbs!.round()}',
          unit: 'lbs',
          icon: Icons.monitor_weight,
          color: NotelColors.info,
        ),
        MetricTile(
          title: 'Resting HR',
          value: d.restingHr == null ? null : '${d.restingHr}',
          unit: 'BPM',
          icon: Icons.bedtime,
          color: const Color(0xFFBA68C8),
          subtitle: d.hcConnected
              ? 'Last daily reading'
              : 'Connect Health Connect to read this',
        ),
        MetricTile(
          title: 'Active Calories',
          value: d.activeCalories == null ? null : '${d.activeCalories}',
          unit: 'kcal',
          icon: Icons.local_fire_department,
          color: NotelColors.warning,
          subtitle: d.hcConnected ? 'Today' : 'Connect Health Connect to read this',
        ),
        const MetricTile(
          title: 'Breathing Rate',
          value: null,
          unit: 'brpm',
          icon: Icons.air,
          color: Color(0xFF81C784),
          customNote: 'Not synced on this build.',
        ),
        const MetricTile(
          title: 'Blood Oxygen',
          value: null,
          unit: '%',
          icon: Icons.opacity,
          color: Color(0xFFFF8A65),
          customNote: 'Not synced on this build.',
        ),
        const MetricTile(
          title: 'HRV',
          value: null,
          unit: 'ms',
          icon: Icons.timeline,
          color: Color(0xFF4DB6AC),
          customNote: 'Not synced on this build.',
        ),
      ],
    );
  }
}

/// Native `MetricTile` port: fixed-height card with icon, value+unit,
/// title, optional subtitle/custom note. `value == null` (or loading)
/// renders "--"/"No Data Recorded" — never invented.
class MetricTile extends StatelessWidget {
  final String title;
  final String? value;
  final String unit;
  final IconData icon;
  final Color color;
  final bool isLoading;
  final String? subtitle;
  final String? customNote;

  const MetricTile({
    super.key,
    required this.title,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
    this.isLoading = false,
    this.subtitle,
    this.customNote,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && !isLoading;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NotelColors.surface.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: NotelColors.legacyDarkHairlineFaint),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (customNote != null && !hasValue)
                Text(customNote!,
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: NotelColors.textSecondary
                            .withValues(alpha: 0.7)))
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        isLoading
                            ? '--'
                            : (value ?? 'No Data Recorded'),
                        style: TextStyle(
                          fontSize: (!hasValue) ? 13 : 32,
                          fontWeight: (!hasValue)
                              ? FontWeight.normal
                              : FontWeight.w900,
                          color: (!hasValue)
                              ? NotelColors.textSecondary
                                  .withValues(alpha: 0.6)
                              : NotelColors.textPrimary,
                        ),
                      ),
                    ),
                    if (hasValue) ...[
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(unit,
                            style: const TextStyle(
                                fontSize: 12,
                                color: NotelColors.textSecondary)),
                      ),
                    ],
                  ],
                ),
              const SizedBox(height: 2),
              Text(title,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: NotelColors.textSecondary)),
              if (subtitle != null && hasValue && customNote == null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!,
                      style: TextStyle(
                          fontSize: 10,
                          color: NotelColors.textSecondary
                              .withValues(alpha: 0.5))),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Pure helpers (unit-tested) ──────────────────────────────────────────────

/// Runs a Health Connect read with a timeout so a stuck MethodChannel
/// (unmocked in tests, wedged natively) can never hang the screen.
/// Null on any failure — the UI renders the honest empty state.
Future<T?> _guarded<T>(Future<T> Function() call) async {
  try {
    return await call().timeout(const Duration(seconds: 10));
  } catch (_) {
    return null;
  }
}

/// Biometric zero rule: 0 is a failed read, never a value.
int? nonZeroInt(dynamic v) {
  if (v is num && v > 0) return v.toInt();
  if (v is String) {
    final n = int.tryParse(v);
    if (n != null && n > 0) return n;
  }
  return null;
}

/// "YYYY-MM-DD" in device-local time.
String _dateStr(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-'
    '${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')}';

const _metricMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// "Oct 11, 2026" — app-bar date line.
String formatMetricDate(DateTime dt) =>
    '${_metricMonths[dt.month - 1]} ${dt.day}, ${dt.year}';
