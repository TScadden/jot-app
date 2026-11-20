import 'progress_report.dart';
import 'weekly_notification.dart';
import 'weekly_report.dart';

/// Weekly Report — Package 2 automation (Team Session #2
/// decision, 2026-11-09, mechanism as amended by the founder
/// change of 2026-11-19; Juno ruling 2026-11-19).
///
/// First-open automation: on the first app open at or after
/// **Sunday 21:00 local** with the due Mon–Sun week not yet
/// generated, generate it through the weekly
/// ReportGenerationService (the page injects that run — foreground
/// grants, hold-until-seen, the Package 1 pattern), evaluate the
/// completeness bar with Package 1's evaluator, archive the
/// outcome, and — ONLY when the bar passes — post the weekly
/// notification on the `Weekly reports` channel.
///
/// There is NO WorkManager and NO server generation in this
/// package: the trigger is evaluated in the foreground, when the
/// weekly surface opens (and again on lifecycle resume while it
/// is mounted). A week the app never opens across is never
/// generated late: see [weeklyDueWeek].

// ── Trigger ────────────────────────────────────────────────────

/// Sunday 21:00 local of [week] — the week's automatic trigger
/// instant (founder change, 2026-11-19, superseding the spec's
/// Monday 07:00).
DateTime weeklyTriggerInstant(WeeklyWeekWindow week) =>
    DateTime(week.end.year, week.end.month, week.end.day, 21);

/// The Mon–Sun week that is due for automatic generation at
/// [now]: the week whose Sunday 21:00 trigger is the most recent
/// one at or before [now].
///
/// - On Sunday at/after 21:00, the CURRENT week (Mon–today) is
///   due; the report covers it through generation time.
/// - Before that instant (any earlier day, or Sunday before
///   21:00), the due week is the PREVIOUS week — its trigger
///   passed last Sunday at 21:00 and it stays the live due week
///   until this Sunday 21:00 supersedes it. On a normal device
///   that week is already in the archive, so the check is a
///   no-op; a device that was closed across last Sunday generates
///   it on this first open, exactly as the first-open rule says.
/// - A week missed ENTIRELY — the app unopened from before its
///   Sunday 21:00 through the FOLLOWING Sunday 21:00 — is
///   superseded by the new due week and is never auto-generated
///   or notified for after the fact: at any moment at most ONE
///   week is due, and it is never a stale one.
WeeklyWeekWindow weeklyDueWeek(DateTime now) {
  final current = WeeklyWeekWindow.containing(now);
  if (!now.isBefore(weeklyTriggerInstant(current))) return current;
  return current.previous;
}

/// The evaluator's `closedBefore` bound for an automatic
/// generation of [week] at [now] (Juno §d Flag 1): while the
/// week's Sunday is still running (generation on that Sunday),
/// only Mon–Sat may count as complete days; once the Sunday has
/// closed (a catch-up open), the whole week may. The page's PDF
/// render and the coordinator's archive evaluation both use
/// this one bound, so the PDF line and the archive record are
/// computed from identical inputs.
DateTime weeklyClosedBefore(WeeklyWeekWindow week, DateTime now) =>
    now.isBefore(week.endExclusive) ? week.end : week.endExclusive;

// ── Generation seam ────────────────────────────────────────────

/// A finished automatic generation, as the page's weekly-service
/// run hands it back: the collected snapshot plus the saved
/// artifact's identity (the PDF itself was saved by the
/// pipeline's save step, exactly as in Package 1).
class WeeklyGenerationResult {
  final ReportSnapshot snapshot;
  final String fileName;
  final String savedPath;

  const WeeklyGenerationResult({
    required this.snapshot,
    required this.fileName,
    required this.savedPath,
  });
}

/// The injected generation run: generates [week] through the
/// weekly ReportGenerationService and returns its ready outcome,
/// or null when the run failed or was cancelled (nothing is
/// archived and nothing is notified for a failed run — the week
/// stays ungenerated and a later open retries it).
typedef WeeklyGenerateFn = Future<WeeklyGenerationResult?> Function(
    WeeklyWeekWindow week, DateTime now);

// ── Outcome ────────────────────────────────────────────────────

enum WeeklyAutoKind {
  /// No week is due ungenerated (the due week is already in the
  /// archive, or an automatic run is already in flight for it).
  notDue,

  /// The pre-generation entitlement check did not resolve to
  /// Premium (free, lapsed, or an unverifiable check — all
  /// fail-closed identically): NO generation ran, NO
  /// notification was sent, the archive is untouched.
  notEntitled,

  /// The generation run itself failed or was cancelled: nothing
  /// archived, nothing notified; the week remains due.
  generationFailed,

  /// The week generated and archived, and the completeness bar
  /// passed: the weekly notification was sent (exactly once).
  generatedNotified,

  /// The week generated and archived, but the bar did not pass:
  /// NO notification. The held outcome is the archive label —
  /// [WeeklyCompleteness.blocked] carries the Juno §a
  /// permission-needed state data (the evaluation's
  /// blockedSections, when the block is a verified denial and
  /// not a contradiction), and
  /// [WeeklyCompleteness.incomplete] carries the verbatim
  /// low-data framing on the evaluation's pdfLine.
  generatedHeld,
}

class WeeklyAutoOutcome {
  final WeeklyAutoKind kind;

  /// The due week this run considered (null only when the
  /// coordinator was constructed without a clock read — never in
  /// practice; every outcome of a real check carries its week).
  final WeeklyWeekWindow? week;

  /// The completeness evaluation, for generated outcomes.
  final WeeklyEvaluation? evaluation;

  /// The archive record written, for generated outcomes.
  final WeeklyArchiveRecord? record;

  const WeeklyAutoOutcome(this.kind, {this.week, this.evaluation, this.record});

  bool get notified => kind == WeeklyAutoKind.generatedNotified;
}

// ── Coordinator ────────────────────────────────────────────────

/// Owns one automatic-generation check: trigger → idempotency →
/// entitlement (fail-closed, PRE-GENERATION) → generation →
/// evaluation (Flag 1) → archive → conditional notification.
///
/// Idempotency, per Mon–Sun week, exactly one automatic
/// generation ever:
/// - the archive is the durable record — a week present in it is
///   never auto-generated again, across relaunches and process
///   restarts (the store is re-read on every check, never
///   cached);
/// - an in-flight guard makes concurrent checks (page load +
///   lifecycle resume landing together) start at most one run;
/// - the generation seam itself runs through the weekly
///   ReportGenerationService, whose own single-run guard is the
///   second lock, and the archive write is an upsert keyed by
///   week, so even a manual regeneration of the same week
///   replaces rather than duplicates the entry.
class WeeklyAutomationCoordinator {
  WeeklyAutomationCoordinator({
    required Future<WeeklyEntitlement> Function() checkEntitlement,
    required WeeklyReportStore store,
    required WeeklyGenerateFn generate,
    required WeeklyNotifier notifier,
  })  : _checkEntitlement = checkEntitlement,
        _store = store,
        _generate = generate,
        _notifier = notifier;

  final Future<WeeklyEntitlement> Function() _checkEntitlement;
  final WeeklyReportStore _store;
  final WeeklyGenerateFn _generate;
  final WeeklyNotifier _notifier;

  bool _inFlight = false;

  /// True while a [maybeGenerate] run is between its trigger
  /// check and its archive write (the page reads this to keep
  /// its own service listener from archiving the same completion
  /// a second time — the coordinator is the archiver for
  /// automatic runs).
  bool get inFlight => _inFlight;

  /// Runs the check once for [now]. Safe to call on every open
  /// and every resume: every early-exit path is a pure read.
  Future<WeeklyAutoOutcome> maybeGenerate({required DateTime now}) async {
    final week = weeklyDueWeek(now);
    if (_inFlight) {
      return WeeklyAutoOutcome(WeeklyAutoKind.notDue, week: week);
    }
    final existing = await _store.readAll();
    if (existing.any((r) => r.weekStartKey == week.startKey)) {
      return WeeklyAutoOutcome(WeeklyAutoKind.notDue, week: week);
    }

    // PRE-GENERATION entitlement (founder clarification,
    // Session #2): verified BEFORE any generation work begins.
    // Fail-closed — a check that throws is never Premium, and
    // free/lapsed alike produce no generation, no notification,
    // and no archive write; existing entries stay untouched.
    WeeklyEntitlement entitlement;
    try {
      entitlement = await _checkEntitlement();
    } catch (_) {
      entitlement = WeeklyEntitlement.free;
    }
    if (entitlement != WeeklyEntitlement.premium) {
      return WeeklyAutoOutcome(WeeklyAutoKind.notEntitled, week: week);
    }

    // Concurrent checks (page load + resume landing together)
    // can both pass the entry guard and the entitlement await;
    // this re-check and the flag set are one synchronous
    // segment, so exactly one of them proceeds to generate.
    if (_inFlight) {
      return WeeklyAutoOutcome(WeeklyAutoKind.notDue, week: week);
    }
    _inFlight = true;
    try {
      // Re-check the archive after the entitlement await: a
      // manual generation of this same week may have landed
      // while the check was in flight.
      final recheck = await _store.readAll();
      if (recheck.any((r) => r.weekStartKey == week.startKey)) {
        return WeeklyAutoOutcome(WeeklyAutoKind.notDue, week: week);
      }

      WeeklyGenerationResult? result;
      try {
        result = await _generate(week, now);
      } catch (_) {
        // A throwing generation seam is a failed generation:
        // nothing archived, nothing notified, the week stays
        // due for a later open (the finally below re-arms the
        // guard).
        result = null;
      }
      if (result == null) {
        return WeeklyAutoOutcome(WeeklyAutoKind.generationFailed,
            week: week);
      }

      final previous = WeeklyReportStore.previousOf(recheck, week);
      // Juno §d Flag 1: a still-running day is never a complete
      // day. The due week's Sunday is still running only when
      // generation happens ON that Sunday (the 21:00 trigger
      // case): closedBefore is then the Sunday itself, so only
      // Mon–Sat may count as complete days and Sunday's partial
      // data contributes no score to the receipt average. On a
      // later catch-up open of the same due week the Sunday has
      // genuinely closed, and the whole week may count — the
      // report covers the week through its generation time in
      // both cases, and the evaluator is told the truth about
      // which days had closed by then.
      final evaluation = evaluateWeeklyCompleteness(
        snapshot: result.snapshot,
        week: week,
        generationCompleted: true,
        closedBefore: weeklyClosedBefore(week, now),
        previousWeek: previous,
      );
      final record = WeeklyArchiveRecord(
        weekStartKey: week.startKey,
        weekEndKey: week.endKey,
        generatedAtMs: result.snapshot.generationTimestampMs,
        fileName: result.fileName,
        savedPath: result.savedPath,
        label: evaluation.label,
        blockedSections: evaluation.blockedSections,
        dailyScoreDays: evaluation.dailyScoreDays,
        sleepNights: evaluation.sleepNights,
        loggedDays: evaluation.loggedDays,
        completeDays: evaluation.completeDays,
        avgScoreCompleteDays: evaluation.avgScoreCompleteDays,
      );
      await _store.upsert(record);

      // The notification gate (Session #2 honesty policy): the
      // "ready" send exists ONLY on the bar-passing path. A
      // blocked week and a low-data week fall through to the
      // held outcome with zero sends — the notifier is never
      // invoked for them.
      if (evaluation.barMet) {
        try {
          await _notifier.showWeeklyReady();
        } catch (_) {
          // A failed post never un-generates the week: the
          // report is archived and ready in-app; the send is
          // best-effort exactly as PR #55's post is.
        }
        return WeeklyAutoOutcome(WeeklyAutoKind.generatedNotified,
            week: week, evaluation: evaluation, record: record);
      }
      return WeeklyAutoOutcome(WeeklyAutoKind.generatedHeld,
          week: week, evaluation: evaluation, record: record);
    } finally {
      _inFlight = false;
    }
  }
}
