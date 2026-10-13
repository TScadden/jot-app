import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

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

  const KeyMetricsScreen({super.key, this.backend, this.healthConnect});

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

  Future<void> _load() async {
    Map<String, dynamic>? profile;
    String? error;
    try {
      profile = await _backend.fetchProfile();
      if (profile == null) {
        error =
            'Could not load your metrics. Check your connection and try again.';
      }
    } catch (_) {
      error =
          'Could not load your metrics. Check your connection and try again.';
    }
    _profile = profile;

    final hcConnected =
        await _guarded(() => _hc.isConnected()) ?? false;

    if (hcConnected) {
      // History sets for the selector/picker selectability (native
      // checks historical HR, sleep, and calories).
      final resting = await _guarded(() => _hc.readRestingHrHistory(7)) ??
          const <({String date, int bpm})>[];
      final sleep = await _guarded(() => _hc.readSleepHistory(7)) ??
          const <({String date, int mins, int deep})>[];
      final calories = await _guarded(() => _hc.readCaloriesHistory(7)) ??
          const <({String date, int kcal})>[];
      _datesWithData = {
        for (final r in resting)
          if (r.bpm > 0) r.date,
        for (final r in sleep)
          if (r.mins > 0) r.date,
        for (final r in calories)
          if (r.kcal > 0) r.date,
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

    if (hcConnected) {
      final samples =
          await _guarded(() => _hc.readHeartRateSamples(key)) ?? const [];
      final daytime = daytimeHeartRateAvg(samples);
      if (daytime != null) avgHr = daytime;

      restingHr = nonZeroInt(await _guarded(() => _hc.readRestingHeartRate(key)));
      if (restingHr == null) {
        final history =
            await _guarded(() => _hc.readRestingHrHistory(7)) ?? const [];
        final rows = history.where((r) => r.date == key && r.bpm > 0);
        if (rows.isNotEmpty) restingHr = rows.last.bpm;
      }

      final weightKg = await _guarded(() => _hc.readLatestWeightKg());
      if (weightKg != null && weightKg > 0) weightLbs = weightKg * 2.20462;

      breathing = nonZeroDouble(
          await _guarded(() => _hc.readRespiratoryRate(key)));
      oxygen =
          nonZeroDouble(await _guarded(() => _hc.readOxygenSaturation(key)));
      hrv = nonZeroDouble(await _guarded(() => _hc.readHrvRmssd(key)));
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
    _perDateCache[key] = data;
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
      final hrHistory =
          await _guarded(() => _hc.readRestingHrHistory(resolvedDays)) ??
              const <({String date, int bpm})>[];
      final sleepHistory =
          await _guarded(() => _hc.readSleepHistory(resolvedDays)) ??
              const <({String date, int mins, int deep})>[];
      final spikeHistory = (includeSpikes && days != -1)
          ? await _guarded(() => _hc.readSpikeCounts(days)) ??
              const <({String date, int count})>[]
          : const <({String date, int count})>[];

      final avgHrByDate = <String, int>{
        for (final r in hrHistory)
          if (r.bpm > 0) r.date: r.bpm,
      };
      final sleepByDate = <String, int>{
        for (final r in sleepHistory) r.date: r.mins,
      };
      final deepByDate = <String, int>{
        for (final r in sleepHistory) r.date: r.deep,
      };
      final spikesByDate = <String, int>{
        for (final r in spikeHistory) r.date: r.count,
      };

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
      final ok = await _guarded(
            () => _hc.exportCsvFile(fileName: fileName, content: csv),
          ) ??
          false;
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Export failed. The CSV could not be shared. Please try again.'),
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
                unit: 'BPM',
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
                        color:
                            NotelColors.textSecondary.withValues(alpha: 0.7)))
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
                              ? NotelColors.textSecondary.withValues(alpha: 0.6)
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
                          color:
                              NotelColors.textSecondary.withValues(alpha: 0.5))),
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

String _csvMins(int mins) => '${mins ~/ 60}h ${mins % 60}m';

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
