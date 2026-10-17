import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart'
    show formatSleepMinutes;
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// R70 Daily Score — history screen + day detail.
///
/// FLAG FOR JUNO: every user-visible string in this file (and in
/// `daily_score_circle.dart`) is proposed copy for her mandatory
/// wording pass. Framing is trend-vs-own-baseline only: no
/// diagnostic terms, no "stress"/"recovery" claims (the three
/// components are labeled as what they are — sleep, HRV, resting
/// heart rate), no vendor language, no accuracy claims. The
/// disclaimer footer is the native MedicalDisclaimerBanner copy,
/// verbatim.
///
/// Data honesty:
/// - The list, the chart, and the scores shown come from the
///   PERSISTED store records (write-once — history as shown is
///   history as scored).
/// - A day detail's baselines are recomputed deterministically
///   from the store data on/before that day via the same pure
///   [computeDailyScore] the engine uses; the persisted score
///   itself is never recomputed for display.
/// - Component presentation is three labeled rows with per-
///   component bars — deliberately NOT a recovery-vs-strain
///   grouping, so the screen never implies a stress or recovery
///   metric the app does not compute.

const List<String> _monthNames = [
  '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const List<String> _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Mon, Oct 12" for a "YYYY-MM-DD" date.
String formatScoreDate(String date) {
  final parsed = DateTime.tryParse(date);
  if (parsed == null) return date;
  return '${_dayNames[parsed.weekday - 1]}, ${_monthNames[parsed.month]} '
      '${parsed.day}';
}

/// "Oct 12" (trend lines).
String formatScoreDateShort(String date) {
  final parsed = DateTime.tryParse(date);
  if (parsed == null) return date;
  return '${_monthNames[parsed.month]} ${parsed.day}';
}

/// Baseline numbers read naturally: whole numbers without a
/// trailing ".0", otherwise one decimal (58 → "58", 58.5 → "58.5").
String _formatBaseline(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// One scored day plus its trend vs the previous scored day.
class _ScoredDay {
  final DailyBiometrics row;
  final DailyBiometrics? previousScored;
  const _ScoredDay(this.row, this.previousScored);

  int? get trendDelta => previousScored == null
      ? null
      : row.dailyScore! - previousScored!.dailyScore!;
}

/// Which components contributed to a persisted score, as plain
/// component names — derived from the non-null component fields,
/// which is exactly the record the engine wrote.
List<String> contributedComponentNames(DailyBiometrics row) => [
      if (row.scoreSleep != null) 'Sleep',
      if (row.scoreHrv != null) 'HRV',
      if (row.scoreRestingHr != null) 'Resting heart rate',
    ];

class DailyScoreScreen extends StatefulWidget {
  /// Injectable for tests; defaults to the shared store.
  final HealthHistoryStore? store;

  const DailyScoreScreen({super.key, this.store});

  @override
  State<DailyScoreScreen> createState() => _DailyScoreScreenState();
}

class _DailyScoreScreenState extends State<DailyScoreScreen> {
  late final HealthHistoryStore _store =
      widget.store ?? HealthHistoryStore.instance;
  List<_ScoredDay> _days = const []; // newest first
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      // Opening the history also runs the compute trigger, so a
      // day whose inputs landed since the last Home load appears.
      await DailyScoreEngine(store: _store).computeMissingScores();
      final all = await _store.readAll();
      final scored = [
        for (final row in all.values)
          if (row.dailyScore != null) row,
      ]; // readAll is ascending by date
      final out = <_ScoredDay>[];
      for (var i = scored.length - 1; i >= 0; i--) {
        out.add(_ScoredDay(scored[i], i > 0 ? scored[i - 1] : null));
      }
      if (!mounted) return;
      setState(() {
        _days = out;
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        title: const Text(
          'Daily Score',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: !_loaded
          ? const SizedBox.shrink()
          : _days.isEmpty
              ? _buildBuildingState()
              : _buildHistory(),
    );
  }

  Widget _buildBuildingState() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 24),
        const Center(child: DailyScoreCircle(score: null)),
        const SizedBox(height: 16),
        const Text(
          'Building baseline',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: NotelColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Your score appears once at least 7 earlier days exist '
          'for one part of the score: sleep, HRV, or resting heart '
          'rate. From then on, each day is scored once, against '
          'your own recent baseline.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: NotelColors.textSecondary),
        ),
        const SizedBox(height: 24),
        _howItWorksCard(),
        const SizedBox(height: 16),
        _disclaimer(),
      ],
    );
  }

  Widget _buildHistory() {
    final chartDays = _days.take(30).toList().reversed.toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _howItWorksCard(),
        const SizedBox(height: 16),
        _chartCard(chartDays),
        const SizedBox(height: 16),
        for (final day in _days) _dayRow(day),
        const SizedBox(height: 8),
        _disclaimer(),
        // Dock clearance: 16 (list padding) + 94 = the 110dp
        // standard, so the last row never hides behind the dock.
        const SizedBox(height: 94),
      ],
    );
  }

  Widget _howItWorksCard() {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NotelColors.legacyDarkDivider),
      ),
      padding: const EdgeInsets.all(16),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How this score works',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Each day is compared with your own recent baseline: '
            'the 28 days before it. Sleep counts 40%, HRV 35%, and '
            'resting heart rate 25%, counting only the parts with '
            'at least 7 baseline days. HRV is measured as RMSSD, '
            'among the most-studied signals in physiology. A day '
            'is scored once and never changes.',
            style: TextStyle(fontSize: 13, color: NotelColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _chartCard(List<_ScoredDay> chartDays) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NotelColors.legacyDarkDivider),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'LAST 30 SCORED DAYS',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: NotelColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 80,
            child: CustomPaint(
              painter: _ScoreBarsPainter([
                for (final d in chartDays) d.row.dailyScore!,
              ]),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dayRow(_ScoredDay day) {
    final row = day.row;
    final band = bandForScore(row.dailyScore!);
    final delta = day.trendDelta;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => unawaited(Navigator.of(context).push(
            SlidePageRoute(
              reducedMotion: animationsDisabled(context),
              builder: (_) =>
                  DailyScoreDayScreen(store: _store, date: row.date),
            ),
          )),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: band.color,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${row.dailyScore}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: NotelColors.background,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatScoreDate(row.date),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: NotelColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          contributedComponentNames(row).join(' · '),
                          style: const TextStyle(
                            fontSize: 11,
                            color: NotelColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (delta != null)
                    Text(
                      delta == 0
                          ? '→ 0'
                          : '${delta > 0 ? '▲' : '▼'} ${delta.abs()}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _disclaimer() {
    return const Text(
      'Tabs is not a medical device. It does not diagnose, treat, '
      'cure, or prevent any condition. AI insights are '
      'informational only. Consult a healthcare professional.',
      style: TextStyle(fontSize: 11, color: NotelColors.textSecondary),
    );
  }
}

/// Bars for the persisted daily scores, oldest → newest, colored
/// by band; height is the score's share of 100.
class _ScoreBarsPainter extends CustomPainter {
  final List<int> scores;
  const _ScoreBarsPainter(this.scores);

  @override
  void paint(Canvas canvas, Size size) {
    if (scores.isEmpty) return;
    final gap = 2.0;
    final barWidth = (size.width - gap * (scores.length - 1)) / scores.length;
    final paint = Paint();
    for (var i = 0; i < scores.length; i++) {
      final score = scores[i];
      paint.color = bandForScore(score).color;
      final h = (score / 100 * size.height).clamp(2.0, size.height);
      final left = i * (barWidth + gap);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(left, size.height - h, barWidth, h),
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ScoreBarsPainter oldDelegate) =>
      oldDelegate.scores != scores;
}

/// Day detail: the day's persisted score, its trend vs the
/// previous scored day, and per-component inputs vs baselines.
class DailyScoreDayScreen extends StatefulWidget {
  final HealthHistoryStore store;
  final String date;

  const DailyScoreDayScreen({
    super.key,
    required this.store,
    required this.date,
  });

  @override
  State<DailyScoreDayScreen> createState() => _DailyScoreDayScreenState();
}

class _DailyScoreDayScreenState extends State<DailyScoreDayScreen> {
  DailyBiometrics? _row;
  DailyBiometrics? _previousScored;
  DailyScoreComputation? _computation;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final all = await widget.store.readAll();
      final row = all[widget.date];
      DailyBiometrics? previous;
      if (row != null) {
        for (final other in all.values) {
          if (other.date.compareTo(widget.date) < 0 &&
              other.dailyScore != null) {
            previous = other; // ascending: last one wins = nearest
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _row = row;
        _previousScored = previous;
        _computation =
            row == null ? null : computeDailyScore(all, widget.date);
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        elevation: 0,
        title: Text(
          formatScoreDate(widget.date),
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: NotelColors.textPrimary,
          ),
        ),
      ),
      body: !_loaded
          ? const SizedBox.shrink()
          : _row?.dailyScore == null
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No score stored for this day.',
                    style: TextStyle(
                        fontSize: 13, color: NotelColors.textSecondary),
                  ),
                )
              : _buildDetail(),
    );
  }

  Widget _buildDetail() {
    final row = _row!;
    final band = bandForScore(row.dailyScore!);
    final prev = _previousScored;
    final delta = prev == null ? null : row.dailyScore! - prev.dailyScore!;
    final prevDate = prev == null ? null : formatScoreDateShort(prev.date);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: band.color,
                ),
                alignment: Alignment.center,
                child: Text(
                  '${row.dailyScore}',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: NotelColors.background,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                band.label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: band.color,
                ),
              ),
              if (delta != null && prevDate != null) ...[
                const SizedBox(height: 4),
                Text(
                  delta == 0
                      ? 'Same as the previous scored day ($prevDate)'
                      : '${delta > 0 ? 'Higher' : 'Lower'} by ${delta.abs()} '
                          'than the previous scored day ($prevDate)',
                  style: const TextStyle(
                    fontSize: 12,
                    color: NotelColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: NotelColors.legacyDarkDivider),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _componentRow(
                name: 'Sleep',
                componentScore: row.scoreSleep,
                detail: _sleepDetail(row),
              ),
              const SizedBox(height: 16),
              _componentRow(
                name: 'HRV (RMSSD)',
                componentScore: row.scoreHrv,
                detail: _hrvDetail(row),
              ),
              const SizedBox(height: 16),
              _componentRow(
                name: 'Resting heart rate',
                componentScore: row.scoreRestingHr,
                detail: _restingHrDetail(row),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Scored once from the data stored for this day. Later '
          'changes to earlier days do not change this score.',
          style: TextStyle(fontSize: 12, color: NotelColors.textSecondary),
        ),
      ],
    );
  }

  /// One component: name + its persisted component score (or
  /// "Not counted"), a bar of the component score, and the
  /// actual-vs-baseline line.
  Widget _componentRow({
    required String name,
    required int? componentScore,
    required String detail,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: NotelColors.textPrimary,
                ),
              ),
            ),
            Text(
              componentScore?.toString() ?? 'Not counted',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: componentScore == null
                    ? NotelColors.textSecondary
                    : NotelColors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (componentScore != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: componentScore / 100,
              minHeight: 8,
              backgroundColor: NotelColors.surfaceHigh,
              valueColor: AlwaysStoppedAnimation<Color>(
                  bandForScore(componentScore).color),
            ),
          ),
        const SizedBox(height: 6),
        Text(
          detail,
          style:
              const TextStyle(fontSize: 12, color: NotelColors.textSecondary),
        ),
      ],
    );
  }

  String _sleepDetail(DailyBiometrics row) {
    if (row.scoreSleep == null) {
      return row.sleepMinutes == null
          ? 'No sleep stored for this night.'
          : 'Not counted: the need estimate needs 7 earlier nights.';
    }
    final c = _computation;
    if (c?.asleepMinutes == null || c?.sleepNeedMinutes == null) {
      return '${formatSleepMinutes(row.sleepMinutes!)} asleep.';
    }
    return '${formatSleepMinutes(c!.asleepMinutes!)} asleep · '
        'your need ${formatSleepMinutes(c.sleepNeedMinutes!)}';
  }

  String _hrvDetail(DailyBiometrics row) {
    if (row.scoreHrv == null) {
      return row.hrvRmssdMs == null
          ? 'No HRV reading stored for this day.'
          : 'Not counted: the baseline needs 7 earlier days.';
    }
    final c = _computation;
    if (c?.hrvBaselineMs == null) {
      return '${row.hrvRmssdMs!.toStringAsFixed(1)} ms.';
    }
    return '${row.hrvRmssdMs!.toStringAsFixed(1)} ms · '
        'your baseline ${_formatBaseline(c!.hrvBaselineMs!)} ms';
  }

  String _restingHrDetail(DailyBiometrics row) {
    if (row.scoreRestingHr == null) {
      return row.restingHrBpm == null
          ? 'No resting heart rate stored for this day.'
          : 'Not counted: the baseline needs 7 earlier days.';
    }
    final c = _computation;
    if (c?.restingHrBaselineBpm == null) {
      return '${row.restingHrBpm} bpm.';
    }
    return '${row.restingHrBpm} bpm · '
        'your baseline ${_formatBaseline(c!.restingHrBaselineBpm!)} bpm';
  }
}
