import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 18 (Team B) — Sleep tool port of the native `SleepScreen.kt`.
/// Round 48 — completed to full native parity:
///
/// Native action surface (all wired):
/// - Sync button (force re-read), Today button (visible when a past
///   date is selected), calendar date picker → `fetchSleepForDate`.
/// - Hero card: minutes asleep for the SELECTED date, sleep deficit,
///   REM, efficiency; tapping shows the Sleep Science dialog.
/// - Compare Days / Compare Weeks: pick a past day (or a week's ending
///   day) → comparison card with the past value, the selected/current
///   week value, the signed difference, and a clear (×) button.
/// - Sleep Stages grid: Deep / Light for the selected date.
/// - Recent Nights (Flutter addition kept from round 18): the 7-day
///   window ending today with per-night totals and a 7-day average.
///
/// Data: Health Connect via the existing bridge — per-day
/// `readSleepMinutes` / `readSleepStages`. Sleep debt: for TODAY the
/// sync-pull profile's `todaySleepDebt` wins — that value is native's
/// own `SyncManager.calculateDebtAtDate` result, synced to the
/// server. For a past selected date the same algorithm is computed
/// locally from the nights already read (`FitbitViewModel.
/// calculateDebtAtDate`: 10-day rolling window ending at the selected
/// date, 8h target, surplus over 8h capped at 1.5h credit/night, debt
/// never below 0). The profile's `todaySleepMins` is only a fallback
/// for today's hero when Health Connect has no session.
///
/// Founder's biometric rule: a 0 is a failed read — never charted,
/// averaged, or displayed as real sleep. Missing → "--".
///
/// Round 48 fix (the tools_team_b Sleep timeouts): every Health
/// Connect read is wrapped in a timeout. Previously a single wedged
/// channel call (unmocked in tests, stuck natively per the team
/// lessons) left `_load()` unresolved forever, so the spinner never
/// cleared and `pumpAndSettle` timed out. A timed-out read now lands
/// in the honest empty state instead.

String _formatMins(int mins) {
  final h = mins ~/ 60;
  final m = mins % 60;
  if (h > 0 && m > 0) return '${h}h ${m}m';
  if (h > 0) return '${h}h';
  return '${m}m';
}

/// Native hero format: always both parts ("7h 30m", "8h 0m").
String formatSleepHeroMins(int mins) => '${mins ~/ 60}h ${mins % 60}m';

/// Native `FitbitViewModel.calculateDebtAtDate`, ported exactly:
/// [history] is (dateStr → minutes) for nights with REAL data (zero /
/// failed reads already removed); only nights ≤ [upToDate] count, the
/// last 10 of them. Returns ≤ 0 minutes (0 = no debt).
int computeSleepDebtMins(Map<String, int> history, String upToDate) {
  final dates = history.keys.where((d) => d.compareTo(upToDate) <= 0).toList()
    ..sort();
  final rolling = dates.length > 10 ? dates.sublist(dates.length - 10) : dates;
  var runningDebt = 0.0;
  for (final date in rolling) {
    final actualHours = (history[date] ?? 0) / 60.0;
    if (actualHours < 8.0) {
      runningDebt += 8.0 - actualHours;
    } else {
      runningDebt -= (actualHours - 8.0).clamp(0.0, 1.5);
    }
    if (runningDebt < 0) runningDebt = 0;
  }
  return (-runningDebt * 60).toInt();
}

/// Average minutes over the 7 days ending at [endDate] (inclusive),
/// counting only nights with real data. Null when no night has data.
/// Ports the native Compare-Weeks math ("sum / count" over the week).
int? sleepWeekAverage(Map<String, int> history, String endDate) {
  final end = DateTime.tryParse(endDate);
  if (end == null) return null;
  var sum = 0;
  var count = 0;
  for (var i = 0; i < 7; i++) {
    final d = end.subtract(Duration(days: i));
    final key = _dateKey(d);
    final mins = history[key];
    if (mins != null && mins > 0) {
      sum += mins;
      count++;
    }
  }
  return count > 0 ? sum ~/ count : null;
}

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class SleepScreen extends StatefulWidget {
  /// Injectable for tests.
  final TabsBackend? backend;

  /// Injectable for tests (a fake can override isConnected/readSleep*).
  final HealthConnectService? healthConnect;

  const SleepScreen({super.key, this.backend, this.healthConnect});

  @override
  State<SleepScreen> createState() => _SleepScreenState();
}

class _SleepScreenState extends State<SleepScreen> {
  late final TabsBackend _backend;
  late final HealthConnectService _hc;

  bool _loading = true;
  bool _refreshing = false;
  bool _connected = false;

  /// All real (positive) minutes read so far, dateStr → minutes.
  final Map<String, int> _history = {};

  String _selectedDate = _dateKey(DateTime.now());
  int? _selectedMins;
  int? _debtMins;
  int? _deepMins;
  int? _lightMins;
  int? _remMins;
  int? _efficiency;
  List<({String dateStr, String dayLabel, int? mins})> _nights = const [];

  String _compareMode = 'Days'; // native compareMode: "Days" | "Weeks"
  ({String dateStr, int mins})? _compare;

  bool get _isTodaySelected => _selectedDate == _dateKey(DateTime.now());

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? TabsBackend();
    _hc = widget.healthConnect ?? HealthConnectService();
    _load();
  }

  /// Guarded Health Connect read: a wedged channel must never hang
  /// the screen (see the class doc — this was the test-timeout cause).
  Future<T?> _guarded<T>(Future<T> Function() call,
      {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      return await call().timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final connected = await _guarded(() => _hc.isConnected()) ?? false;
    if (!connected) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _loading = false;
        _refreshing = false;
      });
      return;
    }

    // Initial window: the last 14 days ending today — covers Recent
    // Nights (7), the debt window (10) and the current-week average.
    final today = DateTime.now();
    final dates = [
      for (var i = 13; i >= 0; i--) _dateKey(today.subtract(Duration(days: i))),
    ];
    await _readMinutesFor(dates);
    await _applySelected(_dateKey(today), useProfileFallback: true);
    if (!mounted) return;
    setState(() {
      _connected = true;
      _loading = false;
      _refreshing = false;
    });
  }

  /// Reads minutes for [dates] not already in [_history] (guarded,
  /// parallel). Zero / null = failed read → stays missing.
  Future<void> _readMinutesFor(List<String> dates) async {
    final missing = dates.where((d) => !_history.containsKey(d)).toList();
    if (missing.isEmpty) return;
    final reads = await _guarded(
          () => Future.wait(missing.map((d) => _hc.readSleepMinutes(d))),
        ) ??
        const [];
    for (var i = 0; i < missing.length && i < reads.length; i++) {
      final raw = reads[i];
      if (raw != null && raw > 0) _history[missing[i]] = raw;
    }
  }

  /// Loads stages for [dateStr] and recomputes hero + debt + nights.
  /// Must be called inside/before a setState by callers that need one.
  Future<void> _applySelected(String dateStr,
      {bool useProfileFallback = false}) async {
    final stages = await _guarded(() => _hc.readSleepStages(dateStr),
        timeout: const Duration(seconds: 3));
    var mins = _history[dateStr] ?? _positiveOrNull(stages?.minutesAsleep);
    int? profileDebt;
    if (useProfileFallback && dateStr == _dateKey(DateTime.now())) {
      try {
        final profile = await _backend.fetchProfile();
        mins ??= _asPositiveInt(profile?['todaySleepMins']);
        profileDebt = _asInt(profile?['todaySleepDebt']);
      } catch (_) {
        // Hero stays "--" — honest empty.
      }
    }
    // Debt needs the 10 nights ending at the selected date.
    final end = DateTime.tryParse(dateStr);
    if (end != null) {
      await _readMinutesFor([
        for (var i = 9; i >= 0; i--)
          _dateKey(end.subtract(Duration(days: i))),
      ]);
      mins ??= _history[dateStr];
    }
    final window = sevenDayWindow();
    _selectedDate = dateStr;
    _selectedMins = mins;
    // Today's deficit is the profile's synced native-computed value
    // when present; a past date's deficit is computed locally from
    // the nights read (native fetchSleepForDate). No data at all →
    // null → "Deficit: --".
    _debtMins = profileDebt ??
        ((_history.isEmpty && mins == null)
            ? null
            : (dateStr == _dateKey(DateTime.now())
                ? null
                : computeSleepDebtMins(_history, dateStr)));
    _deepMins = _positiveOrNull(stages?.deepMinutes);
    _lightMins = _positiveOrNull(stages?.lightMinutes);
    _remMins = _positiveOrNull(stages?.remMinutes);
    _efficiency = _positiveOrNull(stages?.efficiency);
    _nights = [
      for (final d in window)
        (dateStr: d.dateStr, dayLabel: d.dayLabel, mins: _history[d.dateStr]),
    ];
  }

  Future<void> _sync() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    // Drop cached reads so the sync is a real re-read, not a replay.
    _history.clear();
    _backend.invalidateSyncPull();
    final today = DateTime.now();
    final dates = [
      for (var i = 13; i >= 0; i--) _dateKey(today.subtract(Duration(days: i))),
    ];
    // Re-read the selected date's window too when it is in the past.
    if (!_isTodaySelected) {
      final end = DateTime.tryParse(_selectedDate);
      if (end != null) {
        dates.addAll([
          for (var i = 9; i >= 0; i--)
            _dateKey(end.subtract(Duration(days: i))),
        ]);
      }
    }
    await _readMinutesFor(dates.toSet().toList());
    await _applySelected(_selectedDate,
        useProfileFallback: _isTodaySelected);
    if (!mounted) return;
    setState(() => _refreshing = false);
  }

  Future<void> _selectDate(String dateStr) async {
    if (dateStr == _selectedDate && !_loading) return;
    setState(() => _refreshing = true);
    await _readMinutesFor([dateStr]);
    await _applySelected(dateStr);
    if (!mounted) return;
    setState(() => _refreshing = false);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_selectedDate) ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    await _selectDate(_dateKey(picked));
  }

  Future<void> _pickCompare() async {
    final now = DateTime.now();
    if (_compareMode == 'Days') {
      final picked = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: DateTime(now.year - 5),
        lastDate: now,
      );
      if (picked == null || !mounted) return;
      final key = _dateKey(picked);
      await _readMinutesFor([key]);
      final mins = _history[key];
      if (!mounted) return;
      setState(() {
        // Native only sets a comparison when that date has data.
        _compare = mins != null ? (dateStr: key, mins: mins) : null;
      });
    } else {
      final picked = await showDateRangePicker(
        context: context,
        initialDateRange: DateTimeRange(
          start: now.subtract(const Duration(days: 6)),
          end: now,
        ),
        firstDate: DateTime(now.year - 5),
        lastDate: now,
      );
      if (picked == null || !mounted) return;
      // Native uses the range's END date and averages its last 7 days.
      final endKey = _dateKey(picked.end);
      final end = picked.end;
      await _readMinutesFor([
        for (var i = 6; i >= 0; i--)
          _dateKey(end.subtract(Duration(days: i))),
      ]);
      final avg = sleepWeekAverage(_history, endKey);
      if (!mounted) return;
      setState(() {
        _compare = avg != null ? (dateStr: endKey, mins: avg) : null;
      });
    }
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static int? _asPositiveInt(dynamic v) {
    final i = _asInt(v);
    return (i != null && i > 0) ? i : null;
  }

  /// Founder rule: a 0 stage/efficiency value is a missing reading,
  /// never displayed as real data.
  static int? _positiveOrNull(int? v) => (v != null && v > 0) ? v : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back,
            color: NotelColors.textPrimary,
            semanticLabel: 'Back',
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Sleep Profile',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: _connected
            ? [
                IconButton(
                  icon: const Icon(Icons.sync,
                      color: NotelColors.textSecondary,
                      semanticLabel: 'Sync'),
                  onPressed: _refreshing ? null : _sync,
                ),
                if (!_isTodaySelected)
                  IconButton(
                    icon: const Icon(Icons.today,
                        color: NotelColors.textSecondary,
                        semanticLabel: 'Today'),
                    onPressed: _refreshing
                        ? null
                        : () => _selectDate(_dateKey(DateTime.now())),
                  ),
                IconButton(
                  icon: const Icon(Icons.calendar_month,
                      color: NotelColors.textSecondary,
                      semanticLabel: 'Select Date'),
                  onPressed: _refreshing ? null : _pickDate,
                ),
              ]
            : null,
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: NotelColors.primary),
                  SizedBox(height: 16),
                  Text(
                    'Loading Sleep Data...',
                    style: TextStyle(
                      fontSize: 14,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            )
          : !_connected
              ? _notConnectedState()
              : _analysisView(),
    );
  }

  Widget _notConnectedState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: 0.1,
                    child: Container(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: NotelColors.primary,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.hotel,
                    size: 64,
                    color: NotelColors.primary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Sleep Analysis',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Connect your health data to track sleep cycles and calculate your sleep debt automatically.',
              style: TextStyle(
                fontSize: 14,
                height: 1.57,
                color: NotelColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              "Today's sleep: --",
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _analysisView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_refreshing) ...[
            const LinearProgressIndicator(
              color: NotelColors.primary,
              backgroundColor: Colors.transparent,
            ),
            const SizedBox(height: 16),
          ],
          _heroCard(),
          const SizedBox(height: 24),
          _compareButtons(),
          if (_compare != null) ...[
            const SizedBox(height: 16),
            _compareCard(),
          ],
          const SizedBox(height: 24),
          const Text(
            'Sleep Stages',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _stageCard('Deep', _deepMins)),
              const SizedBox(width: 12),
              Expanded(child: _stageCard('Light', _lightMins)),
            ],
          ),
          const SizedBox(height: 24),
          _recentNights(),
        ],
      ),
    );
  }

  Widget _heroCard() {
    final mins = _selectedMins;
    final debt = _debtMins;

    return GestureDetector(
      onTap: _showSleepInfo,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: NotelColors.cardBorder),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.hotel,
              size: 64,
              color: NotelColors.primary,
            ),
            const SizedBox(height: 16),
            Text(
              _isTodaySelected ? 'Time Asleep Today' : 'Daily Time Asleep',
              style: const TextStyle(
                fontSize: 14,
                color: NotelColors.textSecondary,
              ),
            ),
            Text(
              mins != null ? formatSleepHeroMins(mins) : '--',
              style: const TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.w900,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.history,
                  size: 16,
                  color: NotelColors.error,
                ),
                const SizedBox(width: 8),
                Text(
                  debt != null
                      ? 'Deficit: -${debt.abs() ~/ 60}h ${debt.abs() % 60}m'
                      : 'Deficit: --',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.error,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.auto_graph,
                  size: 16,
                  color: NotelColors.info,
                ),
                const SizedBox(width: 8),
                Text(
                  _remMins != null
                      ? 'REM: ${_formatMins(_remMins!)}'
                      : 'REM: --',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: NotelColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: NotelColors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Text(
                _efficiency != null
                    ? 'Efficiency: ${_efficiency!}%'
                    : 'Efficiency: --',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: NotelColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _compareButtons() {
    Widget button(String label, String mode) {
      final selected = _compareMode == mode;
      return Expanded(
        child: FilledButton(
          onPressed: _refreshing
              ? null
              : () {
                  setState(() => _compareMode = mode);
                  _pickCompare();
                },
          style: FilledButton.styleFrom(
            backgroundColor:
                selected ? NotelColors.primary : NotelColors.surfaceHigh,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: selected ? Colors.white : NotelColors.textPrimary,
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        button('Compare Days', 'Days'),
        const SizedBox(width: 8),
        button('Compare Weeks', 'Weeks'),
      ],
    );
  }

  Widget _compareCard() {
    final compare = _compare!;
    final isWeeks = _compareMode == 'Weeks';
    final currentMins = isWeeks
        ? (sleepWeekAverage(_history, _dateKey(DateTime.now())) ??
            _selectedMins ??
            0)
        : (_selectedMins ?? 0);
    final diff = currentMins - compare.mins;
    final diffStr =
        '${diff >= 0 ? '+' : '-'}${diff.abs() ~/ 60}h ${diff.abs() % 60}m';
    final parsed = DateTime.tryParse(compare.dateStr);
    final monthDay = parsed != null
        ? '${_monthFull(parsed.month)} ${parsed.day}'
        : compare.dateStr;
    final displayDate = isWeeks ? 'Week ending $monthDay' : monthDay;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        children: [
          Align(
            alignment: Alignment.topRight,
            child: IconButton(
              icon: const Icon(Icons.close,
                  color: NotelColors.textSecondary,
                  semanticLabel: 'Clear Compare'),
              onPressed: () => setState(() => _compare = null),
            ),
          ),
          Text(
            isWeeks ? 'Weekly Comparison' : 'Daily Comparison',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: NotelColors.primary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '$displayDate: ${formatSleepHeroMins(compare.mins)} avg',
            style: const TextStyle(
              fontSize: 16,
              color: NotelColors.textPrimary,
            ),
          ),
          Text(
            isWeeks
                ? 'This Week: ${formatSleepHeroMins(currentMins)} avg'
                : 'Selected: ${formatSleepHeroMins(currentMins)}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Difference: $diffStr',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: diff < 0 ? NotelColors.error : NotelColors.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stageCard(String label, int? mins) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: NotelColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            mins != null ? _formatMins(mins) : '--',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentNights() {
    final valid = _nights.where((n) => n.mins != null).toList();
    final avgText = valid.isNotEmpty
        ? '7-Day Average: ${_formatMins((valid.map((n) => n.mins!).reduce((a, b) => a + b) / valid.length).round())}'
        : 'Not enough sleep data yet';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recent Nights',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          avgText,
          style: const TextStyle(
            fontSize: 13,
            color: NotelColors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: NotelColors.cardBorder),
          ),
          child: Column(
            children: [
              for (var i = 0; i < _nights.length; i++) ...[
                _nightRow(_nights[i]),
                if (i < _nights.length - 1)
                  Divider(
                    height: 1,
                    color: NotelColors.textSecondary.withValues(alpha: 0.2),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _nightRow(({String dateStr, String dayLabel, int? mins}) night) {
    final parts = night.dateStr.split('-');
    final dateLabel = parts.length == 3
        ? '${_monthName(int.tryParse(parts[1]) ?? 0)} ${int.tryParse(parts[2]) ?? 0}'
        : night.dateStr;
    final isSelected = night.dateStr == _selectedDate;
    return InkWell(
      onTap: () => _selectDate(night.dateStr),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(
              Icons.bedtime,
              size: 20,
              color: NotelColors.primary,
            ),
            const SizedBox(width: 12),
            Text(
              night.dayLabel,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              dateLabel,
              style: const TextStyle(
                fontSize: 13,
                color: NotelColors.textSecondary,
              ),
            ),
            if (isSelected) ...[
              const SizedBox(width: 8),
              const Icon(Icons.check_circle,
                  size: 14, color: NotelColors.primary),
            ],
            const Spacer(),
            Text(
              night.mins != null ? _formatMins(night.mins!) : '--',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: night.mins != null
                    ? NotelColors.textPrimary
                    : NotelColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _monthName(int m) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return (m >= 1 && m <= 12) ? months[m] : '';
  }

  String _monthFull(int m) {
    const months = [
      '', 'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return (m >= 1 && m <= 12) ? months[m] : '';
  }

  void _showSleepInfo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: const Text(
          'Sleep Science',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tabs uses a 10-day rolling window to calculate your sleep debt. Surplus sleep (over 8h) is capped at 1.5h of recovery credit per night.',
              style: TextStyle(
                fontSize: 14,
                color: NotelColors.textSecondary,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'REM sleep is crucial for cognitive function and emotional regulation. Most adults need 1.5h to 2h of REM per night.',
              style: TextStyle(
                fontSize: 14,
                color: NotelColors.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Got it',
              style: TextStyle(color: NotelColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}
