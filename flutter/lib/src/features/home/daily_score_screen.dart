import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_refresh.dart';
import 'package:tabs_lab/src/data/daily_score_refresh_owner.dart';
import 'package:tabs_lab/src/data/refresh_keep_alive.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart'
    show historyDateStr;
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/daily_score_vocabulary.dart';
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
///   PERSISTED store records (write-once for every automatic
///   path — history as shown is history as scored, until the
///   founder explicitly refreshes a day from its detail screen;
///   see [DailyScoreRefresher]).
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

  /// Injectable for tests: the day detail's app-scoped refresh
  /// owner. Defaults to [DailyScoreRefreshOwner.instance].
  final DailyScoreRefreshOwner? refreshOwner;

  /// Injectable for tests: the snapshot capture run before the
  /// history's compute trigger (founder amendment, Oct 20, 2026).
  /// Defaults to a non-forced capture through a sync bound to the
  /// screen's store.
  final ScoreCapture? snapshotCapture;

  const DailyScoreScreen(
      {super.key, this.store, this.refreshOwner, this.snapshotCapture});

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

  /// Builds the newest-first scored-day list from a store read
  /// (readAll is ascending by date).
  List<_ScoredDay> _scoredDaysFrom(Map<String, DailyBiometrics> all) {
    final scored = [
      for (final row in all.values)
        if (row.dailyScore != null) row,
    ];
    final out = <_ScoredDay>[];
    for (var i = scored.length - 1; i >= 0; i--) {
      out.add(_ScoredDay(scored[i], i > 0 ? scored[i - 1] : null));
    }
    return out;
  }

  Future<void> _load() async {
    // PAINT-FIRST (Oct 22, 2026): paint the PERSISTED store scores
    // immediately, before any capture or compute. A due capture
    // used to leave this screen literally blank (SizedBox.shrink)
    // for the reads' full duration — the founder opened the app
    // and saw no data until a manual forced refresh. The first
    // paint performs NO compute and persists nothing: it is a
    // plain store read, exactly the history as last scored.
    try {
      final all = await _store.readAll();
      if (!mounted) return;
      setState(() {
        _days = _scoredDaysFrom(all);
        _loaded = true;
      });
    } catch (_) {
      // Same defined state the old single-chain catch produced:
      // loaded, empty — the building state.
      if (!mounted) return;
      setState(() => _loaded = true);
    }
    // BACKGROUND REFRESH: the existing snapshot → compute →
    // re-read chain, unchanged and in the same order, now runs
    // behind the painted list and repaints when it lands.
    try {
      // SNAPSHOT-FIRST (founder amendment, Oct 20, 2026): the
      // compute below first awaits a Health Connect capture — the
      // snapshot — so a new score is never computed from stale
      // store state when fresher data is obtainable. The capture
      // stays under its normal rules (NON-forced, 6h throttle;
      // only the day detail's refresh button forces one): when it
      // is throttled or skipped, this load scores from the store
      // exactly as the last completed capture left it. The
      // capture's own post-capture run is the only automatic run
      // that may score today, and only when today is complete.
      final snapshot = widget.snapshotCapture ??
          HealthHistorySync.withDeps(store: _store).capture;
      await snapshot(force: false);
      // This screen's own compute run stays cut off BEFORE today
      // (TODAY RULE, daily_score.dart): it backfills past days
      // under the day-boundary fallback but never scores today.
      await DailyScoreEngine(store: _store).computeMissingScores(
          beforeDate: historyDateStr(DateTime.now()));
      final all = await _store.readAll();
      if (!mounted) return;
      setState(() {
        _days = _scoredDaysFrom(all);
        _loaded = true;
      });
    } catch (_) {
      // The painted stored days stay up — a failed background
      // chain never blanks a painted screen.
      if (!mounted) return;
      if (!_loaded) setState(() => _loaded = true);
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
          ? const Center(child: CircularProgressIndicator())
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
          'your own recent baseline, and a scored day changes '
          'only when you refresh it.',
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
    final chartDays = _days.take(14).toList().reversed.toList();
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
            'Each day is compared with your own recent baseline: the most recent 28 days with data before it. Sleep counts 40%, HRV 35%, and resting heart rate 25%, counting only the parts with at least 7 baseline days. HRV is measured as RMSSD, among the most-studied signals in physiology. A day is scored once and does not change on its own. You can refresh a day from its detail screen.',
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
            'Last 14 scored days',
            // Card-title role (16 bold), matching the sibling
            // "How this score works" card on this same screen and
            // the Home card titles (Mira pass — was 14 w500, a
            // row-title style doing a card title's job).
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: NotelColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 104,
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

  /// Opens a day detail and, on return, reloads the list (the
  /// same pattern Home uses after the score screen pops), so a
  /// score refreshed in the detail shows in the list without
  /// re-entering the screen.
  Future<void> _openDay(String date) async {
    await Navigator.of(context).push(
      SlidePageRoute(
        reducedMotion: animationsDisabled(context),
        builder: (_) => DailyScoreDayScreen(
          store: _store,
          date: date,
          refreshOwner: widget.refreshOwner,
        ),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  Widget _dayRow(_ScoredDay day) {
    final row = day.row;
    final delta = day.trendDelta;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => unawaited(_openDay(row.date)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  DailyScoreFace(score: row.dailyScore, size: 34),
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

/// The concept's 14-day chart: Tabs-purple bars for the persisted
/// daily scores, oldest → newest, each bar NUMBERED above it, the
/// latest day highlighted (lighter tint + bold number). Height is
/// the score's share of 100. Only days that hold a persisted score
/// appear — never zero-filled placeholders for unscored days.
class _ScoreBarsPainter extends CustomPainter {
  final List<int> scores;
  const _ScoreBarsPainter(this.scores);

  @override
  void paint(Canvas canvas, Size size) {
    if (scores.isEmpty) return;
    const labelHeight = 16.0;
    final chartHeight = size.height - labelHeight;
    final slot = size.width / scores.length;
    final barWidth = math.min(16.0, slot * 0.55);
    final paint = Paint();
    for (var i = 0; i < scores.length; i++) {
      final score = scores[i];
      final isLatest = i == scores.length - 1;
      paint.color = isLatest ? NotelColors.primaryText : NotelColors.primary;
      final h = (score / 100 * chartHeight).clamp(2.0, chartHeight);
      final centerX = slot * i + slot / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
              centerX - barWidth / 2, size.height - h, barWidth, h),
          const Radius.circular(4),
        ),
        paint,
      );
      final label = TextPainter(
        text: TextSpan(
          text: '$score',
          style: TextStyle(
            fontSize: 10,
            fontWeight: isLatest ? FontWeight.bold : FontWeight.w500,
            color:
                isLatest ? NotelColors.textPrimary : NotelColors.textSecondary,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(centerX - label.width / 2, size.height - h - labelHeight),
      );
    }
  }

  @override
  bool shouldRepaint(_ScoreBarsPainter oldDelegate) =>
      oldDelegate.scores != scores;
}

/// Plain names for the capture's metric keys, for surfacing
/// per-metric refresh failures to the user (the capture records
/// diagnostics under its own internal names — see
/// [HealthHistoryStore.lastCaptureDiagnostics]).
const Map<String, String> _captureMetricLabels = {
  'restingHr': 'Resting heart rate',
  'calories': 'Calories',
  'sleep': 'Sleep',
  'spikes': 'Heart rate spikes',
  'hrv': 'HRV',
};

/// The busy reason shown (tooltip + semantics label, verbatim —
/// Juno ruling, Oct 20, 2026) on a day's refresh control while a
/// refresh for a DIFFERENT day is in flight: refreshes are
/// single-flight app-wide, so this day's control is disabled with
/// the reason stated, never silently idle or silently missing.
const String dailyScoreRefreshBusyOtherDayReason =
    'A refresh is already running for another day.';

/// Day detail: the day's persisted score, its trend vs the
/// previous scored day, and per-component inputs vs baselines.
///
/// The screen also carries the founder-directed refresh control
/// (Oct 20, 2026): tapping it force-captures Health Connect and
/// re-scores THIS day from the store's updated data, through
/// [DailyScoreRefresher] — the one user-initiated exception to
/// write-once scoring, and exempt from the completeness gate, so
/// it also appears on unscored days and on today's pending state.
/// Automatic behavior is unchanged.
///
/// Refresh STATE is not the screen's (founder-directed Oct 20,
/// 2026): the app-scoped [DailyScoreRefreshOwner] owns the
/// in-flight flag and the outcome. The screen renders its control
/// from the owner's state (busy during ANY refresh — this day's
/// shows its own progress, another day's shows the disabled
/// control with [dailyScoreRefreshBusyOtherDayReason]), consumes
/// outcomes the owner records for this date, and can be unmounted
/// mid-refresh without cancelling, losing, or duplicating
/// anything: an outcome that completes while the user is
/// elsewhere is surfaced inline, once, on the next entry to this
/// day (Juno's deferred-surfacing ruling — inline only, no
/// SnackBar on entry).
class DailyScoreDayScreen extends StatefulWidget {
  final HealthHistoryStore store;
  final String date;

  /// Injectable for tests; defaults to the app-scoped
  /// [DailyScoreRefreshOwner.instance].
  final DailyScoreRefreshOwner? refreshOwner;

  const DailyScoreDayScreen({
    super.key,
    required this.store,
    required this.date,
    this.refreshOwner,
  });

  @override
  State<DailyScoreDayScreen> createState() => _DailyScoreDayScreenState();
}

class _DailyScoreDayScreenState extends State<DailyScoreDayScreen> {
  DailyBiometrics? _row;
  DailyBiometrics? _previousScored;
  DailyScoreComputation? _computation;
  bool _loaded = false;

  /// The app-scoped refresh owner: in-flight state and outcomes
  /// live there, never in this State, so leaving this screen
  /// mid-refresh loses nothing.
  late final DailyScoreRefreshOwner _owner =
      widget.refreshOwner ?? DailyScoreRefreshOwner.instance;

  /// The surfaced outcome of the last refresh of THIS day that
  /// this screen consumed from the owner: the capture-failure code,
  /// the per-metric failure codes its capture newly recorded, and
  /// the honest no-score notice when a refresh produced no score
  /// for a still-unscored day. (In-flight state is NOT mirrored
  /// here — the build reads it from the owner directly.)
  String? _refreshErrorCode;
  Map<String, String> _refreshFailureCodes = const {};
  String? _refreshNotice;

  /// Whether the last refresh of THIS day surfaced here had a
  /// failed keep-alive start (Juno Ruling 3): renders Juno's exact
  /// line as its own line AFTER the refresh's own outcome lines,
  /// once — the flag it came from is consumed together with the
  /// outcome, on both the witnessed and deferred paths.
  bool _refreshKeepAliveFailed = false;

  /// False until the entry load + entry consume have run. The
  /// listener does not consume outcomes before then: anything
  /// already recorded when this screen opened is a DEFERRED
  /// outcome (it completed before entry, or during the entry
  /// load) and must surface inline-only, so the entry path —
  /// never the listener — is its one consumer.
  bool _entrySettled = false;

  /// Bumped on every in-place re-dating (see [didUpdateWidget]):
  /// an entry load started for a superseded date must not consume
  /// or settle the entry for the date now shown.
  int _entryEpoch = 0;

  @override
  void initState() {
    super.initState();
    _owner.addListener(_onOwnerChanged);
    unawaited(_loadAndConsumePending());
  }

  /// Production navigation pushes a fresh route per day, but a
  /// retained State whose [DailyScoreDayScreen.date] changes in
  /// place must not keep showing (or consuming for) the old day:
  /// reset every entry-scoped field and run the same
  /// load-then-consume entry path a fresh mount runs, for the
  /// NEW date. Without this, an in-place re-date silently renders
  /// the previous day's score and never surfaces the new day's
  /// deferred outcome.
  @override
  void didUpdateWidget(DailyScoreDayScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date == widget.date) return;
    _entryEpoch++;
    _entrySettled = false;
    _row = null;
    _previousScored = null;
    _computation = null;
    _loaded = false;
    _refreshErrorCode = null;
    _refreshFailureCodes = const {};
    _refreshNotice = null;
    _refreshKeepAliveFailed = false;
    unawaited(_loadAndConsumePending());
  }

  @override
  void dispose() {
    _owner.removeListener(_onOwnerChanged);
    super.dispose();
  }

  /// Entry: load from the store, then consume any outcome a
  /// refresh of this day completed while the user was elsewhere.
  /// Consuming REMOVES the record (the owner's consume-once), so
  /// the deferred surfacing below renders exactly once — never
  /// again on rotation, back-and-return, or a later entry.
  Future<void> _loadAndConsumePending() async {
    final epoch = _entryEpoch;
    final date = widget.date;
    await _load();
    // A re-date superseded this entry while it loaded: the new
    // date's own entry path owns consuming and settling.
    if (!mounted || epoch != _entryEpoch) return;
    final outcome = _owner.consumeOutcome(date);
    // Consumed together with the outcome (Juno Ruling 3): this
    // refresh's keep-alive-failure flag, taken exactly once.
    final keepAliveFailed = _owner.consumeKeepAliveFailure(date);
    _entrySettled = true;
    if (outcome == null) {
      // A flag with no outcome is the late-start-failure case
      // (the owner's start resolved only after its outcome was
      // already consumed): Juno's line still surfaces, alone.
      if (keepAliveFailed && mounted) {
        setState(() => _refreshKeepAliveFailed = true);
      }
      return;
    }
    // Deferred surfacing (Juno ruling): INLINE ONLY — the live
    // SnackBar belongs to completions this screen witnessed.
    await _surfaceOutcome(outcome,
        witnessed: false, keepAliveFailed: keepAliveFailed);
  }

  /// Owner state changed: a refresh started somewhere (re-render
  /// this day's control from the owner's busy state), or one
  /// completed. A completion for THIS day while this screen is
  /// mounted is consumed and surfaced exactly as the screen has
  /// always reacted (reload; SnackBar on capture failure).
  void _onOwnerChanged() {
    if (!mounted) return;
    if (!_entrySettled) {
      // Still entering: only the busy state can have changed.
      // Any outcome recorded for this date belongs to the entry
      // consume (deferred, inline-only) — see [_entrySettled].
      setState(() {});
      return;
    }
    final outcome = _owner.consumeOutcome(widget.date);
    // Consumed together with the outcome (Juno Ruling 3), exactly
    // as on the entry path — the witnessed path renders Juno's
    // line once for this refresh too.
    final keepAliveFailed = _owner.consumeKeepAliveFailure(widget.date);
    if (outcome == null) {
      // No outcome: either a plain state change (re-render), or
      // a LATE keep-alive flag for an outcome this screen already
      // surfaced — Juno's line renders then, on its own.
      if (keepAliveFailed) {
        setState(() => _refreshKeepAliveFailed = true);
      } else {
        setState(() {});
      }
      return;
    }
    unawaited(_surfaceOutcome(outcome,
        witnessed: true, keepAliveFailed: keepAliveFailed));
  }

  /// Renders one consumed refresh [outcome] for this day. On
  /// capture failure the displayed score stays untouched and the
  /// error is shown plainly, code included — plus the SnackBar
  /// when this screen [witnessed] the completion (a deferred
  /// failure surfaces inline only, Juno ruling). Otherwise the
  /// screen first reloads from the persisted record, then
  /// surfaces any per-metric read failures the capture recorded
  /// (the rescore proceeded from store truth, so these explain
  /// what could NOT be refreshed), and — only while the day still
  /// has no score — the honest no-score notice: a no-change
  /// outcome for a day that HAS a score needs no notice (Juno
  /// ruling), and a successful refresh needs none either (the new
  /// number is the outcome).
  Future<void> _surfaceOutcome(
    DailyScoreRefreshOutcome outcome, {
    required bool witnessed,
    required bool keepAliveFailed,
  }) async {
    if (outcome.status == DailyScoreRefreshStatus.captureFailed) {
      if (!mounted) return;
      setState(() {
        _refreshErrorCode = dailyScoreRefreshCaptureFailedCode;
        _refreshFailureCodes = const {};
        _refreshNotice = null;
        _refreshKeepAliveFailed = keepAliveFailed;
      });
      if (witnessed) {
        _showRefreshError(dailyScoreRefreshCaptureFailedCode);
      }
      return;
    }
    await _load();
    if (!mounted) return;
    setState(() {
      _refreshErrorCode = null;
      _refreshFailureCodes = outcome.newFailureCodes;
      _refreshKeepAliveFailed = keepAliveFailed;
      _refreshNotice =
          outcome.status == DailyScoreRefreshStatus.noChange &&
                  _row?.dailyScore == null
              ? 'Still no score for this day: not enough stored '
                  'health data to score it yet.'
              : null;
    });
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

  /// The refresh tap: asks the owner to re-score this day from
  /// freshly captured data (see [DailyScoreRefresher] for the
  /// full semantics). The owner REFUSES while any refresh is in
  /// flight app-wide, so a tap can never start a second forced
  /// capture. The screen does not await the refresh: the owner
  /// notifies on completion and [_onOwnerChanged] surfaces the
  /// outcome — and if the user leaves first, the outcome waits in
  /// the owner for the next entry to this day.
  void _onRefresh() {
    // A fresh tap supersedes any deferred outcome still recorded
    // for this day: consume and discard it so its lines never
    // render alongside the new refresh's own outcome.
    _owner.consumeOutcome(widget.date);
    _owner.consumeKeepAliveFailure(widget.date);
    final started = _owner.startRefresh(widget.date);
    if (started == null) return; // refused: a refresh is in flight
    setState(() {
      _refreshErrorCode = null;
      _refreshFailureCodes = const {};
      _refreshNotice = null;
      _refreshKeepAliveFailed = false;
    });
  }

  /// The refresh control, rendered from the OWNER's state:
  ///
  /// - This day is refreshing: disabled + progress (further taps
  ///   are refused by the owner regardless).
  /// - ANOTHER day is refreshing: disabled + progress, carrying
  ///   [dailyScoreRefreshBusyOtherDayReason] as BOTH its tooltip
  ///   and its semantics label, with semantics exposing the
  ///   control as a disabled button with that reason (Juno
  ///   ruling: bare disabled+spinner is not enough, and the
  ///   control must stay in the tree, not vanish).
  /// - Idle: the refresh button.
  ///
  /// Re-entering the refreshing day mid-flight therefore shows
  /// its busy state, never an idle button over the stale score.
  Widget _refreshControl() {
    if (_owner.isRefreshingDate(widget.date)) {
      return IconButton(
        key: const ValueKey('daily-score-refresh'),
        tooltip: 'Refresh score',
        // Material's IconButton tap target is 48dp by default.
        // In flight the control disables and swaps to a progress
        // indicator.
        onPressed: null,
        icon: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_owner.isRefreshing) {
      return SizedBox(
        key: const ValueKey('daily-score-refresh'),
        width: 48,
        height: 48,
        child: Tooltip(
          message: dailyScoreRefreshBusyOtherDayReason,
          child: Semantics(
            button: true,
            enabled: false,
            label: dailyScoreRefreshBusyOtherDayReason,
            child: const ExcludeSemantics(
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return IconButton(
      key: const ValueKey('daily-score-refresh'),
      tooltip: 'Refresh score',
      onPressed: _onRefresh,
      icon: const Icon(Icons.refresh, color: NotelColors.primary),
    );
  }

  void _showRefreshError(String code) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not refresh. Please try again. [$code]'),
      ),
    );
  }

  /// The refresh outcome lines, shared by the scored detail and
  /// the no-score state: a capture failure (the score — or the
  /// pending state — was left untouched), the per-metric failures
  /// the last capture newly recorded, and the no-score notice.
  /// Because BOTH the scored detail and the no-score builder
  /// (pending today + past unscored days) render these lines,
  /// every Juno-final string here reads true in all three states.
  List<Widget> _refreshNotices() => [
        if (_refreshErrorCode != null) ...[
          const SizedBox(height: 16),
          Text(
            'Refresh failed. Nothing was changed. '
            '[$_refreshErrorCode]',
            style: const TextStyle(fontSize: 12, color: NotelColors.error),
          ),
        ],
        if (_refreshFailureCodes.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Some data could not be read in this refresh: '
            '${_refreshFailureCodes.entries.map((e) => '${_captureMetricLabels[e.key] ?? e.key} [${e.value}]').join(', ')}'
            '. Any score shown uses only the data that is stored.',
            style: const TextStyle(fontSize: 12, color: NotelColors.warning),
          ),
        ],
        if (_refreshNotice != null) ...[
          const SizedBox(height: 16),
          Text(
            _refreshNotice!,
            style: const TextStyle(
                fontSize: 12, color: NotelColors.textSecondary),
          ),
        ],
        // Juno Ruling 3 — LAST, as its own line, never merged
        // with the refresh's own outcome lines above: one
        // non-modal line when this refresh's keep-alive start
        // failed. No dialog, toast, or banner.
        if (_refreshKeepAliveFailed) ...[
          const SizedBox(height: 16),
          const Text(
            dailyScoreRefreshKeepAliveFailedLine,
            style: TextStyle(fontSize: 12, color: NotelColors.warning),
          ),
        ],
      ];

  /// The no-score state. For TODAY this is the completeness
  /// gate's pending state (founder amendment, Oct 20, 2026): an
  /// honest "waiting for data" message, no number — the bare
  /// "No score stored" line is not enough for today. Past
  /// unscored days keep the plain line. Either way the refresh
  /// control stays available: a tap scores the day immediately
  /// from a forced snapshot when any data exists for it.
  Widget _buildNoScore() {
    final isToday = widget.date == historyDateStr(DateTime.now());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          isToday
              ? 'Today\'s score is waiting for today\'s health data. '
                  'Tabs can score today once sleep, HRV, and resting '
                  'heart rate are all available and counted. You can '
                  'also tap refresh to score it now from the data '
                  'already stored.'
              : 'No score stored for this day.',
          style: const TextStyle(
              fontSize: 13, color: NotelColors.textSecondary),
        ),
        ..._refreshNotices(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // The refresh control shows in every loaded state where a
    // score could result (founder amendment, Oct 20, 2026):
    // scored days, unscored days with a store row, and today's
    // pending state — a forced snapshot can land data for any of
    // them, and a tap that still finds nothing ends in the honest
    // no-score state with the outcome surfaced.
    final showRefresh = _loaded;
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
        actions: [
          if (showRefresh) _refreshControl(),
        ],
      ),
      body: !_loaded
          ? const SizedBox.shrink()
          : _row?.dailyScore == null
              ? _buildNoScore()
              : _buildDetail(),
    );
  }

  Widget _buildDetail() {
    final row = _row!;
    final band = bandForScore(row.dailyScore!);
    final prev = _previousScored;
    final delta = prev == null ? null : row.dailyScore! - prev.dailyScore!;
    final prevDate = prev == null ? null : formatScoreDateShort(prev.date);
    final isToday = widget.date == historyDateStr(DateTime.now());
    final c = _computation;
    final sleepChip =
        row.scoreSleep == null ? null : sleepChipForScore(row.scoreSleep!);
    final hrvChip = (row.scoreHrv == null ||
            c?.hrvMs == null ||
            c?.hrvBaselineMs == null)
        ? null
        : hrvChipForDeviation(
            (c!.hrvMs! - c.hrvBaselineMs!) / c.hrvBaselineMs! * 100);
    final restingHrChip = (row.scoreRestingHr == null ||
            c?.restingHrBpm == null ||
            c?.restingHrBaselineBpm == null)
        ? null
        : restingHrChipForDeviation(
            (c!.restingHrBpm! - c.restingHrBaselineBpm!) /
                c.restingHrBaselineBpm! *
                100);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Column(
            children: [
              DailyScoreFace(
                score: row.dailyScore,
                size: 84,
                showInnerLabel: true,
              ),
              const SizedBox(height: 12),
              Text(
                isToday
                    ? '${formatScoreDate(row.date)} · Today'
                    : formatScoreDate(row.date),
                style: const TextStyle(
                  fontSize: 13,
                  color: NotelColors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              // The concept's day chip: "Daily Score: 78 · Good".
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: band.color.withValues(alpha: 0.18),
                  // Chip radius 12 (closed scale §6), as on the
                  // Home band chip (Mira pass).
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Daily Score: ${row.dailyScore} · ${band.label}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: band.color,
                  ),
                ),
              ),
              if (delta != null && prevDate != null) ...[
                const SizedBox(height: 8),
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
                icon: Icons.bedtime,
                tint: NotelColors.info,
                name: 'Sleep',
                componentScore: row.scoreSleep,
                detail: _sleepDetail(row),
                chip: sleepChip,
              ),
              const SizedBox(height: 16),
              _componentRow(
                icon: Icons.graphic_eq,
                tint: NotelColors.primary,
                name: 'HRV (RMSSD)',
                componentScore: row.scoreHrv,
                detail: _hrvDetail(row),
                chip: hrvChip,
              ),
              const SizedBox(height: 16),
              _componentRow(
                icon: Icons.favorite,
                tint: NotelColors.heartRateRed,
                name: 'Resting heart rate',
                componentScore: row.scoreRestingHr,
                detail: _restingHrDetail(row),
                chip: restingHrChip,
              ),
            ],
          ),
        ),
        ..._refreshNotices(),
        const SizedBox(height: 16),
        const Text(
          'This score uses the data stored for this day and your '
          'baseline from earlier days. It does not change on its '
          'own. It changes only when you refresh it.',
          style: TextStyle(fontSize: 12, color: NotelColors.textSecondary),
        ),
        const SizedBox(height: 16),
        // Juno C7 — the disclaimer footer, appended at the end of
        // the day-detail list, verbatim as on the history screen.
        const Text(
          'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition. AI insights are informational only. Consult a healthcare professional.',
          style: TextStyle(fontSize: 11, color: NotelColors.textSecondary),
        ),
      ],
    );
  }

  /// One component, concept-style: a tinted icon square, the name
  /// and the actual-vs-baseline line, the component's status chip,
  /// and (when the component counted) a bar of its persisted
  /// component score. A component that did not count shows
  /// "Not counted" and the honest reason in place of the chip.
  Widget _componentRow({
    required IconData icon,
    required Color tint,
    required String name,
    required int? componentScore,
    required String detail,
    required ScoreChip? chip,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: tint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: const TextStyle(
                      fontSize: 12,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (chip != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: chip.background,
                  // Chip radius 12 (closed scale §6), as on the
                  // Home band chip (Mira pass).
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  chip.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: chip.foreground,
                  ),
                ),
              )
            else if (componentScore == null)
              const Text(
                'Not counted',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: NotelColors.textSecondary,
                ),
              ),
          ],
        ),
        if (componentScore != null) ...[
          const SizedBox(height: 8),
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
        ],
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
    // The concept's sleep line, verbatim format: "7h29m of 8h27m need".
    return '${formatSleepMinutes(c!.asleepMinutes!)} of '
        '${formatSleepMinutes(c.sleepNeedMinutes!)} need';
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
