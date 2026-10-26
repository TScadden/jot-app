import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

/// Key Metrics — Flutter port of the native `KeyMetricsScreen.kt`.
///
/// Round 48 — completed to full native parity. Native action surface:
/// - App-bar date line for the selected date.
/// - Last-7-days selector row (a day is tappable only when it has
///   data — native checks its historical HR / sleep / calories sets;
///   today is always tappable).
/// - Calendar picker (same selectability rule + never a future date)
///   → loads that date's metrics (`fetchMetricsForDate`).
/// - Export Biometrics CSV dialog: range radio (7 / 30 / 90 / 180
///   days / All Time), "Include Heart Rate Spikes" switch (forced off
///   and disabled for All Time, exactly like native), Export →
///   builds the native CSV and hands it to the bridge, which writes
///   it to Downloads and opens the share sheet (native
///   `exportMetricsCsvAsync`).
/// - The six native tiles, in native order: Heart Rate, Weight,
///   Breathing Rate, Blood Oxygen, Resting HR, HRV. (The round-18
///   port's extra "Active Calories" tile is NOT a native Key Metrics
///   tile and is removed; its placeholder "Not synced on this build"
///   tiles are now real reads.)
///
/// Data per date (Health Connect via the bridge, all guarded with
/// timeouts so a wedged channel can never hang the screen):
/// - Heart Rate: daytime (7am–11pm) average of the day's intraday
///   samples (founder rule); falls back to the profile's
///   `todayAvgHr` for today only.
/// - Weight: latest Health Connect weight, else the profile's
///   `weightKg` (native's profile-weight fallback), shown in lbs.
/// - Breathing Rate / Blood Oxygen / HRV: the Round 48 bridge reads
///   (ports of the native HealthConnectManager functions).
/// - Resting HR: the day's resting-HR record, with the resting-HR
///   history as fallback.
///
/// Founder's data rules: a biometric 0 is a failed read (never shown
/// or averaged), missing values render as "--"/"No Data Recorded",
/// and the native "calculated at night" note shows on today's tile
/// when Breathing Rate / Blood Oxygen / HRV have no reading yet.
class KeyMetricsScreen extends StatefulWidget {
  final TabsBackend? backend;
  final HealthConnectService? healthConnect;

  /// R70 WS2 — injectable union reader (store ∪ fresh HC). Null in
  /// production (built from [healthConnect]).
  final HealthHistoryQueries? historyQueries;

  const KeyMetricsScreen(
      {super.key, this.backend, this.healthConnect, this.historyQueries});

  @override
  State<KeyMetricsScreen> createState() => _KeyMetricsScreenState();
}

class _MetricsData {
  final int? avgHr;
  final double? weightLbs;
  final double? breathingRate;
  final double? bloodOxygen;
  final int? restingHr;
  final double? hrv;
  final bool hcConnected;

  const _MetricsData({
    this.avgHr,
    this.weightLbs,
    this.breathingRate,
    this.bloodOxygen,
    this.restingHr,
    this.hrv,
    this.hcConnected = false,
  });
}

class _KeyMetricsScreenState extends State<KeyMetricsScreen> {
  TabsBackend get _backend => widget.backend ?? TabsBackend();
  HealthConnectService get _hc => widget.healthConnect ?? HealthConnectService();

  /// R70 WS2 — one union reader instance for the screen, so its
  /// per-metric failure tracking (the service's error code) always
  /// refers to the same HealthConnectService the union reads from.
  late final HealthHistoryQueries _queries = widget.historyQueries ??
      HealthHistoryQueries(hc: widget.healthConnect ?? HealthConnectService());

  /// Union analogue of [_readGuarded]: a timed-out / throwing load,
  /// or one whose result names failed metrics, reports failed —
  /// a failed history read must never masquerade as empty history.
  Future<({HistoryUnion? value, bool failed})> _unionGuarded(
      Future<HistoryUnion> Function() call) async {
    try {
      final value = await call().timeout(const Duration(seconds: 10));
      return (value: value, failed: value.failedMetrics.isNotEmpty);
    } catch (_) {
      return (value: null, failed: true);
    }
  }

  bool _loading = true;
  bool _exporting = false;
  _MetricsData _data = const _MetricsData();
  String? _error;
  DateTime _selectedDate = DateTime.now();

  /// Dates (yyyy-MM-dd) known to have data, from the history reads —
  /// drives the day-selector / calendar selectability like native.
  Set<String> _datesWithData = const {};
  Map<String, dynamic>? _profile;
  final Map<String, _MetricsData> _perDateCache = {};

  String get _selectedKey => _dateStr(_selectedDate);
  bool get _isTodaySelected => _selectedKey == _dateStr(DateTime.now());

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Vera F5 (fix round): a guarded Health Connect read that does
  /// NOT swallow the failure signal. The service fails closed
  /// (empty list / null) and records the failure in
  /// [HealthConnectService.lastReadErrorCode]; the old `_guarded`
  /// dropped that, so a timed-out or failed read was
  /// indistinguishable from a genuinely-empty day. This wrapper:
  /// - clears the recorded code before the call (the service keeps
  ///   it sticky across successes — the Heart screen's reset rule),
  /// - reports `failed: true` when the call throws / times out, or
  ///   when the service recorded an error code during the call,
  /// - reports `failed: false` for a clean return, INCLUDING a
  ///   genuinely-empty / null result.
  Future<({T? value, bool failed})> _readGuarded<T>(
      Future<T> Function() call) async {
    _hc.lastReadErrorCode = null;
    try {
      final value = await call().timeout(const Duration(seconds: 10));
      return (value: value, failed: _hc.lastReadErrorCode != null);
    } catch (_) {
      return (value: null, failed: true);
    }
  }

  /// Concurrent-batch analogue of [_readGuarded], used by
  /// [_loadDate]: the caller clears
  /// [HealthConnectService.lastReadErrorCode] ONCE before the batch
  /// starts, and each read CLAIMS the recorded code in its own
  /// completion continuation (reads it, then clears it) instead of
  /// clearing up front — clearing per read would erase a concurrent
  /// read's failure signal before its owner could see it. Platform
  /// replies are delivered one message at a time and Dart
  /// microtasks (these continuations) flush between messages, so
  /// the first continuation to run after a code is set belongs to
  /// the read that set it: failure attribution stays per-read,
  /// exactly as the sequential [_readGuarded] (the same protocol
  /// the union reader uses — see health_history_queries.dart).
  /// A throwing / timed-out read still reports failed via the
  /// catch, and only for itself.
  Future<({T? value, bool failed})> _readGuardedClaim<T>(
      Future<T> Function() call) async {
    try {
      final value = await call().timeout(const Duration(seconds: 10));
      final failed = _hc.lastReadErrorCode != null;
      if (failed) _hc.lastReadErrorCode = null;
      return (value: value, failed: failed);
    } catch (_) {
      return (value: null, failed: true);
    }
  }

  Future<void> _load() async {
    // Perf fix: the profile pull (network) and the Health Connect
    // connection check (bridge) are independent — start both before
    // awaiting either, instead of paying them serially.
    final profileFuture = _backend.fetchProfile();
    final connectedFuture = _guarded(() => _hc.isConnected());
    Map<String, dynamic>? profile;
    String? error;
    try {
      profile = await profileFuture;
      if (profile == null) {
        error =
            'Could not load your metrics. Check your connection and try again.';
      }
    } catch (_) {
      error =
          'Could not load your metrics. Check your connection and try again.';
    }
    _profile = profile;

    final hcConnected = await connectedFuture ?? false;

    if (hcConnected) {
      // History sets for the selector/picker selectability (native
      // checks historical HR, sleep, and calories). R70 WS2: from
      // the union — the maps only carry real (positive) values.
      final union = await _guarded(() => _queries.loadDays(7, metrics: {
            HistoryMetric.restingHr,
            HistoryMetric.sleep,
            HistoryMetric.calories,
          }));
      _datesWithData = {
        ...?union?.restingHr.keys,
        ...?union?.sleepMinutes.keys,
        ...?union?.calories.keys,
      };
    }

    final data = await _loadDate(_selectedDate, hcConnected: hcConnected);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
      _data = data;
    });
  }

  Future<_MetricsData> _loadDate(DateTime date,
      {required bool hcConnected}) async {
    final key = _dateStr(date);
    final cached = _perDateCache[key];
    if (cached != null) return cached;

    int? avgHr;
    double? weightLbs;
    double? breathing;
    double? oxygen;
    int? restingHr;
    double? hrv;

    final profile = _profile;
    final kg = profile?['weightKg'];
    if (kg is num && kg > 0) weightLbs = kg.toDouble() * 2.20462;
    if (key == _dateStr(DateTime.now())) {
      avgHr = nonZeroInt(profile?['todayAvgHr']);
    }

    // Vera F5(b): if ANY read for this date failed / timed out, the
    // assembled result is incomplete — it must NOT enter
    // _perDateCache, or the fake-empty values would be served for
    // the whole session. Genuinely-empty results (clean reads, no
    // data) cache exactly as before.
    var anyReadFailed = false;
    if (hcConnected) {
      // Perf fix: the six day reads are independent bridge calls —
      // they used to run one after another (up to six 10s-bounded
      // round-trips in series). Starting every guarded read before
      // awaiting any of them runs them concurrently; the results
      // are then applied in the original precedence order below, so
      // values and fallbacks are unchanged. Each read keeps its own
      // error isolation via _readGuardedClaim: one failed read
      // still only marks this date load failed (F5b), never throws.
      _hc.lastReadErrorCode = null;
      final hrFuture = _readGuardedClaim(() => _hc.readHeartRateSamples(key));
      final restingFuture =
          _readGuardedClaim(() => _hc.readRestingHeartRate(key));
      final weightFuture = _readGuardedClaim(() => _hc.readLatestWeightKg());
      final respFuture =
          _readGuardedClaim(() => _hc.readRespiratoryRate(key));
      final oxyFuture = _readGuardedClaim(() => _hc.readOxygenSaturation(key));
      final hrvFuture = _readGuardedClaim(() => _hc.readHrvRmssd(key));

      final hr = await hrFuture;
      anyReadFailed = anyReadFailed || hr.failed;
      final samples = hr.value ?? const <HrSample>[];
      final daytime = daytimeHeartRateAvg(samples);
      if (daytime != null) avgHr = daytime;

      final resting = await restingFuture;
      anyReadFailed = anyReadFailed || resting.failed;
      restingHr = nonZeroInt(resting.value);
      if (restingHr == null) {
        // R70 WS2 — the resting-HR history fallback reads the union
        // (store ∪ fresh HC); a failed union read marks the date
        // load failed exactly as a failed bridge read did (F5b).
        final hist = await _unionGuarded(() =>
            _queries.loadDays(7, metrics: {HistoryMetric.restingHr}));
        anyReadFailed = anyReadFailed || hist.failed;
        restingHr = hist.value?.restingHr[key];
      }

      final weight = await weightFuture;
      anyReadFailed = anyReadFailed || weight.failed;
      final weightKg = weight.value;
      if (weightKg != null && weightKg > 0) weightLbs = weightKg * 2.20462;

      final resp = await respFuture;
      anyReadFailed = anyReadFailed || resp.failed;
      breathing = nonZeroDouble(resp.value);
      final oxy = await oxyFuture;
      anyReadFailed = anyReadFailed || oxy.failed;
      oxygen = nonZeroDouble(oxy.value);
      final hrvRes = await hrvFuture;
      anyReadFailed = anyReadFailed || hrvRes.failed;
      hrv = nonZeroDouble(hrvRes.value);
    }

    final data = _MetricsData(
      avgHr: avgHr,
      weightLbs: weightLbs,
      breathingRate: breathing,
      bloodOxygen: oxygen,
      restingHr: restingHr,
      hrv: hrv,
      hcConnected: hcConnected,
    );
    if (!anyReadFailed) _perDateCache[key] = data;
    return data;
  }

  Future<void> _selectDate(DateTime date) async {
    if (_dateStr(date) == _selectedKey && !_loading) return;
    setState(() {
      _selectedDate = date;
      _loading = true;
    });
    final data = await _loadDate(date, hcConnected: _data.hcConnected);
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
    });
  }

  bool _dateHasData(DateTime date) {
    final key = _dateStr(date);
    return key == _dateStr(DateTime.now()) || _datesWithData.contains(key);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      selectableDayPredicate: _dateHasData,
    );
    if (picked == null || !mounted) return;
    await _selectDate(picked);
  }

  // ── CSV export (native exportMetricsCsv + dialog) ────────────────

  Future<void> _exportCsv(int days, bool includeSpikes) async {
    setState(() => _exporting = true);
    try {
      final resolvedDays = days == -1 ? 3650 : days;
      // Vera F5(a): a failed / timed-out history read ABORTS the
      // export. The old guarded reads failed closed to empty lists,
      // so an outage produced an authoritative-looking CSV full of
      // "No data" and a success report. Genuinely-empty history
      // (clean reads, no error code) still exports "No data" rows
      // exactly as before.
      //
      // R70 WS2: the export reads through the union helper, so the
      // CSV now reflects the store's full depth (the founder-facing
      // payoff of WS1/WS2) — for "All Time" the store IS the range.
      // The F5(a) discipline is preserved through the union's
      // per-metric failure flags: any failed fresh read among the
      // exported metrics aborts, exactly as before.
      final unionRes = await _unionGuarded(() => _queries.loadDays(
            resolvedDays,
            metrics: {
              HistoryMetric.restingHr,
              HistoryMetric.sleep,
              if (includeSpikes && days != -1) HistoryMetric.spikes,
            },
          ));
      if (unionRes.failed || unionRes.value == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Export failed. Your history could not be read, so nothing was exported. Please try again.'),
          ),
        );
        return;
      }
      final union = unionRes.value!;
      // The union maps are already zero-filtered (a 0 biometric is
      // a failed read); buildMetricsCsv renders missing as
      // "No data", and a spike count of 0 stays real.
      final avgHrByDate = union.restingHr;
      final sleepByDate = union.sleepMinutes;
      final deepByDate = union.deepSleepMinutes;
      final spikesByDate = union.spikes;

      final List<String> dates;
      if (days == -1) {
        final allKeys = <String>{
          ...avgHrByDate.keys,
          ...sleepByDate.keys,
          ...deepByDate.keys,
          ...spikesByDate.keys,
        }..removeWhere((d) => d.isEmpty);
        if (allKeys.isEmpty) {
          dates = const [];
        } else {
          final earliest = allKeys.reduce((a, b) => a.compareTo(b) < 0 ? a : b);
          final start = DateTime.tryParse(earliest) ?? DateTime.now();
          final today = DateTime.now();
          final count = today.difference(DateTime(start.year, start.month, start.day)).inDays;
          dates = [
            for (var i = 0; i <= count; i++)
              _dateStr(today.subtract(Duration(days: i))),
          ];
        }
      } else {
        dates = [
          for (var i = 0; i < days; i++)
            _dateStr(DateTime.now().subtract(Duration(days: i))),
        ];
      }

      final csv = buildMetricsCsv(
        datesDesc: dates,
        avgHrByDate: avgHrByDate,
        sleepByDate: sleepByDate,
        deepByDate: deepByDate,
        spikesByDate: spikesByDate,
      );
      final fileName =
          days == -1 ? 'jot_metrics_alltime.csv' : 'jot_metrics_${days}d.csv';
      final exportRes = await _readGuarded(
        () => _hc.exportCsvFile(fileName: fileName, content: csv),
      );
      final ok = !exportRes.failed && (exportRes.value ?? false);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Export failed. The CSV could not be shared. Please try again.'),
          ),
        );
      } else if (union.partialMetrics.isNotEmpty) {
        // Partial history (Vera F2): the export went out with the
        // data that could be read — it is NOT aborted — but the
        // user is told some history may be missing.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Exported with a warning: some history could not be read and may be missing from the CSV.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showExportDialog() {
    var selectedDays = 30;
    var includeSpikes = true;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: NotelColors.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Export Biometrics CSV',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          content: RadioGroup<int>(
            groupValue: selectedDays,
            onChanged: (v) => setDialogState(() {
              selectedDays = v ?? selectedDays;
              if (selectedDays == -1) includeSpikes = false;
            }),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Select how far back you want the download to go:',
                    style: TextStyle(
                      fontSize: 14,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final (days, label) in const [
                    (7, 'Last 7 Days'),
                    (30, 'Last 30 Days'),
                    (90, 'Last 90 Days'),
                    (180, 'Last 180 Days'),
                    (-1, 'All Time'),
                  ])
                    InkWell(
                      onTap: () => setDialogState(() {
                        selectedDays = days;
                        if (days == -1) includeSpikes = false;
                      }),
                      child: Row(
                        children: [
                          Radio<int>(
                            value: days,
                            activeColor: NotelColors.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            label,
                            style: const TextStyle(
                              fontSize: 16,
                              color: NotelColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Include Heart Rate Spikes',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: selectedDays == -1
                                    ? NotelColors.textSecondary
                                        .withValues(alpha: 0.5)
                                    : NotelColors.textPrimary,
                              ),
                            ),
                            Text(
                              selectedDays == -1
                                  ? 'you can not toggle it on when you are on all time'
                                  : 'Calculates POTS spikes. Turning off makes export instant.',
                              style: TextStyle(
                                fontSize: 12,
                                color: selectedDays == -1
                                    ? NotelColors.primary
                                    : NotelColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: includeSpikes,
                        onChanged: selectedDays == -1
                            ? null
                            : (v) => setDialogState(() => includeSpikes = v),
                        activeTrackColor: NotelColors.primary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  _exporting ? null : () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: NotelColors.textSecondary)),
            ),
            FilledButton(
              onPressed: _exporting
                  ? null
                  : () {
                      Navigator.of(dialogContext).pop();
                      _exportCsv(selectedDays, includeSpikes);
                    },
              style: FilledButton.styleFrom(
                backgroundColor: NotelColors.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: _exporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : const Text('Export',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
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
              formatMetricDate(_selectedDate),
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.primary),
            ),
          ],
        ),
        actions: [
          if (_exporting)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    color: NotelColors.primary, strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.download,
                  color: NotelColors.textSecondary,
                  semanticLabel: 'Export CSV'),
              onPressed: _showExportDialog,
            ),
          IconButton(
            icon: const Icon(Icons.calendar_month,
                color: NotelColors.textSecondary,
                semanticLabel: 'Select Date'),
            onPressed: _pickDate,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const SkeletonGroup(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 110),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(height: 48, radius: 12),
              SizedBox(height: 16),
              SkeletonBox(height: 150, radius: 20),
              SizedBox(height: 16),
              SkeletonBox(height: 150, radius: 20),
            ],
          ),
        ),
      );
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
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _perDateCache.clear();
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
    final isToday = _isTodaySelected;
    String? nightNote(String name, Object? value) =>
        (isToday && value == null)
            ? '$name is calculated at night. Check back tomorrow.'
            : null;

    return Column(
      children: [
        _daySelector(),
        const SizedBox(height: 16),
        Expanded(
          child: GridView.count(
            crossAxisCount: 2,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.78,
            children: [
              MetricTile(
                title: 'Heart Rate',
                value: d.avgHr == null ? null : '${d.avgHr}',
                unit: 'bpm',
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
                title: 'Breathing Rate',
                value: d.breathingRate?.toStringAsFixed(1),
                unit: 'brpm',
                icon: Icons.air,
                color: const Color(0xFF81C784),
                subtitle: 'Last daily reading',
                customNote: nightNote('Breathing Rate', d.breathingRate),
              ),
              MetricTile(
                title: 'Blood Oxygen',
                value: d.bloodOxygen?.toStringAsFixed(1),
                unit: '%',
                icon: Icons.opacity,
                color: const Color(0xFFFF8A65),
                subtitle: 'Last daily reading',
                customNote: nightNote('Blood Oxygen', d.bloodOxygen),
              ),
              MetricTile(
                title: 'Resting HR',
                value: d.restingHr == null ? null : '${d.restingHr}',
                unit: 'bpm',
                icon: Icons.bedtime,
                color: const Color(0xFFBA68C8),
                subtitle: 'Last daily reading',
              ),
              MetricTile(
                title: 'HRV',
                value: d.hrv?.toStringAsFixed(0),
                unit: 'ms',
                icon: Icons.timeline,
                color: const Color(0xFF4DB6AC),
                customNote: nightNote('HRV', d.hrv),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Native last-7-days selector: weekday label + circled day number;
  /// days without data are dimmed and not tappable.
  Widget _daySelector() {
    final today = DateTime.now();
    final days = [
      for (var i = 6; i >= 0; i--) today.subtract(Duration(days: i)),
    ];
    const weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final date in days)
            Builder(builder: (context) {
              final hasData = _dateHasData(date);
              final isSelected = _dateStr(date) == _selectedKey;
              return Opacity(
                opacity: hasData ? 1 : 0.3,
                child: InkWell(
                  onTap: hasData ? () => _selectDate(date) : null,
                  borderRadius: BorderRadius.circular(24),
                  child: SizedBox(
                    width: 44,
                    child: Column(
                      children: [
                        Text(
                          weekdayLabels[date.weekday - 1],
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected
                                ? NotelColors.primary
                                : NotelColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected
                                ? NotelColors.primary.withValues(alpha: 0.2)
                                : Colors.transparent,
                            border: Border.all(
                              width: isSelected ? 2 : 1,
                              color: isSelected
                                  ? NotelColors.primary
                                  : NotelColors.surfaceHigh
                                      .withValues(alpha: 0.5),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${date.day}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? NotelColors.textPrimary
                                  : NotelColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
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
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NotelColors.cardBorder),
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
                        color: NotelColors.textSecondary))
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        isLoading ? '--' : (value ?? 'No Data Recorded'),
                        style: TextStyle(
                          fontSize: (!hasValue) ? 13 : 32,
                          fontWeight:
                              (!hasValue) ? FontWeight.normal : FontWeight.w900,
                          color: (!hasValue)
                              ? NotelColors.textSecondary
                              : NotelColors.textPrimary,
                        ),
                      ),
                    ),
                    if (hasValue) ...[
                      SizedBox(width: unit == '%' ? 0 : 4),
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
                      style: const TextStyle(
                          fontSize: 11, color: NotelColors.textSecondary)),
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

/// Biometric zero rule for doubles (server numbers may be strings).
double? nonZeroDouble(dynamic v) {
  if (v is num && v > 0) return v.toDouble();
  if (v is String) {
    final n = double.tryParse(v);
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

// ── CSV export (native FitbitViewModel.exportMetricsCsv port) ─────────────

/// Native `centerPad`: centers [text] in [width] with spaces.
String centerPadCsv(String text, int width) {
  if (text.length >= width) return text;
  final total = width - text.length;
  final left = total ~/ 2;
  final right = total - left;
  return '${' ' * left}$text${' ' * right}';
}

/// R61 — CSV sleep/deep-sleep durations use the single shared compact
/// formatter (founder ruling, Oct 15, 2026: `7h6m` everywhere).
String _csvMins(int mins) => formatSleepMinutes(mins);

/// Builds the native biometrics CSV: header
/// `Date,Average HR (BPM),Sleep Duration,Deep Sleep,Spikes (count)`,
/// one center-padded row per date in [datesDesc] (newest first).
/// Missing or zero biometrics render "No data" (native rule — a 0 is
/// a failed read); a spike count of 0 is real and prints "0".
String buildMetricsCsv({
  required List<String> datesDesc,
  required Map<String, int> avgHrByDate,
  required Map<String, int> sleepByDate,
  required Map<String, int> deepByDate,
  required Map<String, int> spikesByDate,
}) {
  final csv = StringBuffer()
    ..writeln('Date,Average HR (BPM),Sleep Duration,Deep Sleep,Spikes (count)');
  String value(String? v) => v ?? 'No data';
  for (final date in datesDesc) {
    final avg = avgHrByDate[date];
    final sleep = sleepByDate[date];
    final deep = deepByDate[date];
    final spikes = spikesByDate[date];
    csv.writeln(
      '${centerPadCsv(date, 10)},'
      '${centerPadCsv(value(avg != null && avg > 0 ? '$avg' : null), 18)},'
      '${centerPadCsv(value(sleep != null && sleep > 0 ? _csvMins(sleep) : null), 14)},'
      '${centerPadCsv(value(deep != null && deep > 0 ? _csvMins(deep) : null), 10)},'
      '${centerPadCsv(value(spikes?.toString()), 14)}',
    );
  }
  return csv.toString();
}
