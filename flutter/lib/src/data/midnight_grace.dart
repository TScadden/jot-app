import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:tabs_lab/src/data/tabs_day.dart';

/// Midnight Grace (founder spec, Nov 21, 2026).
///
/// When the Tabs day boundary (local midnight, VC 100147) crosses
/// WHILE the app is foregrounded AND the closing day's Daily
/// Summary is incomplete, a 90-second grace window opens: the
/// closing day's settlement is deferred, and completions inside
/// the window count toward the CLOSING day (see
/// summary_completeness.dart's watcher overrides). At expiry with
/// the day still incomplete, settlement proceeds exactly like a
/// normal rollover. Backgrounding/killing the app mid-grace ends
/// grace; an app that was closed (or backgrounded) AT the crossing
/// never gets grace — there is no retroactive grace on a later
/// open.
///
/// This controller lives ABOVE Home (owned by MainShell) so the
/// crossing is detected wherever the user is in the app: the
/// window runs even when Home is not mounted, and Home's band
/// subscribes when it becomes visible. The controller owns ONLY
/// the window lifecycle — eligibility evidence (is the closing day
/// incomplete?) is answered by the registered evaluator (Home's
/// completeness machinery), and settlement stays StreakStore's.
///
/// Clock and scheduler are injectable: production uses the wall
/// clock and [Timer]; tests drive a fake clock and fire the
/// captured callbacks by hand. The tick chain re-schedules itself
/// through the same one-shot factory, so one seam drives both the
/// crossing timer and the countdown ticks.

/// Why a grace window ended.
enum GraceEndReason {
  /// The closing day completed inside the window.
  completed,

  /// The 90 seconds ran out with the day incomplete.
  expired,

  /// The app left the foreground mid-grace.
  backgrounded,

  /// Home mounted during a provisionally-opened window and found
  /// the closing day was already complete (no evaluator was
  /// mounted at the crossing to answer up front).
  alreadyComplete,
}

/// One live grace window. [closingDayStart] is the Tabs-day start
/// of the day that just closed; [boundary] is the boundary instant
/// that was crossed; [deadline] is boundary + the window length —
/// the closing day's completeness evidence window extends to it.
class GraceWindow {
  final DateTime closingDayStart;
  final DateTime boundary;
  final DateTime deadline;

  const GraceWindow({
    required this.closingDayStart,
    required this.boundary,
    required this.deadline,
  });

  /// The closing day's Tabs-day key (`yyyy-MM-dd`).
  String get closingDayStr => tabsDayFormat(closingDayStart);
}

class MidnightGraceController extends ChangeNotifier
    with WidgetsBindingObserver {
  /// The founder-set window length.
  static const Duration defaultWindowLength = Duration(seconds: 90);

  final DateTime Function() _clock;
  final Timer Function(Duration, void Function()) _scheduleOnce;

  /// How long the window stays open after the boundary.
  final Duration windowLength;

  /// Countdown refresh cadence while a window is active.
  final Duration tickInterval;

  MidnightGraceController({
    DateTime Function()? clock,
    Timer Function(Duration, void Function())? scheduleOnce,
    this.windowLength = defaultWindowLength,
    this.tickInterval = const Duration(milliseconds: 250),
  })  : _clock = clock ?? DateTime.now,
        _scheduleOnce = scheduleOnce ?? Timer.new;

  /// The completeness oracle, registered by Home while it is
  /// mounted: given the closing day's start and the grace
  /// deadline, returns true when the closing day's Daily Summary
  /// is INCOMPLETE (grace should open / stay open). Null when no
  /// Home is mounted — a crossing then opens the window
  /// PROVISIONALLY and Home resolves it on mount (see
  /// [resolveAlreadyComplete]).
  Future<bool> Function(DateTime closingDayStart, DateTime deadline)?
      closingDayIncompleteEvaluator;

  /// Called once per window end, AFTER the window has cleared, so
  /// the listener (Home) can run the normal post-window paths:
  /// expiry/background → the ordinary recordOpen settlement;
  /// completion → nothing extra (the watcher already counted the
  /// day). Never called for a crossing that granted no grace.
  void Function(GraceEndReason reason, GraceWindow window)? onGraceEnded;

  GraceWindow? _window;
  Timer? _crossingTimer;
  Timer? _tickTimer;
  bool _started = false;
  bool _disposed = false;
  bool _evaluatingCrossing = false;

  /// Completed when the in-flight crossing evaluation resolves
  /// (window opened or not). Lets a settlement that arrived
  /// mid-evaluation wait for the answer instead of either settling
  /// ungated or being stranded when no window opens (Vera C1,
  /// race C). Null whenever no evaluation is running.
  Completer<void>? _crossingEvaluationCompleter;

  /// Last known lifecycle state. The shell is created in the
  /// foreground, so the honest initial value is resumed; every
  /// transition updates it through [didChangeAppLifecycleState].
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  /// The live window, or null. Read by Home's band (timer display),
  /// its watcher evaluation (fireable day + evidence end), and its
  /// settlement gate.
  GraceWindow? get activeWindow => _window;

  bool get isActive => _window != null;

  /// While a window is live, NO settle path may settle the closing
  /// day as missed — Home's recordOpen gate reads this. The gate
  /// lifts the moment the window ends (any reason), and the normal
  /// settlement then runs.
  ///
  /// Vera C1 (race C): the gate ALSO holds while a crossing
  /// evaluation is in flight — between the boundary and the
  /// evaluator's answer there is no window yet, but the crossing
  /// is unresolved, and a settle in that interval would
  /// freeze-bridge the closing day before grace could open. The
  /// invariant is: no recordOpen for the closing day at any moment
  /// in [boundary, deadline) while the crossing is unresolved OR
  /// a window is active.
  bool get settlementDeferred => isActive || _evaluatingCrossing;

  /// Whether a crossing evaluation is currently in flight (the
  /// evaluator has been called and has not yet answered).
  bool get isEvaluatingCrossing => _evaluatingCrossing;

  /// Resolves when the in-flight crossing evaluation resolves —
  /// immediately when none is running. A settlement deferred ONLY
  /// by an unresolved crossing awaits this, then re-reads
  /// [settlementDeferred]: if a window opened it stays deferred
  /// (the grace-end handler re-runs the settle); if the crossing
  /// resolved with no window, the settle proceeds — a skipped
  /// settle self-heals here and is never silently stranded.
  Future<void> waitForCrossingEvaluation() {
    if (!_evaluatingCrossing) return Future<void>.value();
    return _crossingEvaluationCompleter?.future ?? Future<void>.value();
  }

  /// Time left in the live window (zero when none / at expiry).
  Duration get remaining {
    final w = _window;
    if (w == null) return Duration.zero;
    final left = w.deadline.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// The band's timer text: `M:SS` — "1:30" at the open, ticking
  /// down by whole seconds (floor, so the last partial second
  /// reads "0:00" only at the deadline itself).
  String get timerText {
    final totalSeconds = remaining.inMilliseconds ~/ 1000;
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Begin observing the lifecycle and arm the crossing timer.
  /// Idempotent; production calls this once from the shell.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _armCrossingTimer();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _crossingTimer?.cancel();
    _tickTimer?.cancel();
    // Never leave a settlement parked on a dead controller.
    final completer = _crossingEvaluationCompleter;
    _crossingEvaluationCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    super.dispose();
  }

  // ── Crossing scheduling ──────────────────────────────────────

  /// Arm a one-shot timer for the next Tabs-day boundary strictly
  /// after now. Re-arming cancels any pending crossing timer, so
  /// resume/re-evaluation paths can call it freely.
  void _armCrossingTimer() {
    _crossingTimer?.cancel();
    if (_disposed) return;
    final now = _clock();
    final boundary = TabsDayBoundary.instance.nextBoundary(now);
    _crossingTimer = _scheduleOnce(
      boundary.difference(now),
      () => unawaited(handleCrossingTimerFired()),
    );
  }

  /// The crossing timer's target — also the test seam: a test sets
  /// the fake clock to just past a boundary and calls this.
  ///
  /// Eligibility, all evaluated at the fire instant:
  /// - the app is foregrounded (lifecycle resumed) — a crossing
  ///   that happened while backgrounded grants NO grace;
  /// - the fire is not stale: now must be within the would-be
  ///   window (a timer that only fired after the app was suspended
  ///   past the deadline grants nothing);
  /// - the closing day is incomplete, per the registered
  ///   evaluator; with no evaluator mounted the window opens
  ///   provisionally (Home resolves it when it mounts).
  Future<void> handleCrossingTimerFired() async {
    if (_disposed || _window != null || _evaluatingCrossing) return;
    final at = _clock();
    // The boundary that opened the day containing [at]: the start
    // of the current Tabs day. The closing day is the one that
    // ended there.
    final boundary = TabsDayBoundary.instance.dayStart(at);
    final deadline = boundary.add(windowLength);
    if (at.isAfter(deadline)) {
      // Stale fire (suspension, late delivery): the window would
      // already be over — no grace, just re-arm for the next day.
      _armCrossingTimer();
      return;
    }
    if (_lifecycle != AppLifecycleState.resumed) {
      _armCrossingTimer();
      return;
    }
    final closingDayStart =
        TabsDayBoundary.instance.dayStart(boundary.subtract(
      const Duration(milliseconds: 1),
    ));
    final evaluator = closingDayIncompleteEvaluator;
    if (evaluator != null) {
      _evaluatingCrossing = true;
      _crossingEvaluationCompleter = Completer<void>();
      bool incomplete;
      try {
        incomplete = await evaluator(closingDayStart, deadline);
      } catch (_) {
        // A failed evaluation grants nothing this crossing; the
        // normal rollover governs (never trap settlement behind a
        // broken grace check).
        incomplete = false;
      } finally {
        _evaluatingCrossing = false;
        // Wake any settlement waiting on this crossing BEFORE the
        // window-open checks below run: those checks and
        // _openWindow are synchronous from here, so a woken
        // settle's re-check always observes the final outcome
        // (window active, or crossing resolved with no window).
        final completer = _crossingEvaluationCompleter;
        _crossingEvaluationCompleter = null;
        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
      }
      // The world may have moved during the evaluation: the app
      // backgrounded, the deadline passed, or a window opened by
      // another path — in every case grace no longer applies.
      if (_disposed || _window != null) return;
      if (_lifecycle != AppLifecycleState.resumed) {
        _armCrossingTimer();
        return;
      }
      if (_clock().isAfter(deadline)) {
        _armCrossingTimer();
        return;
      }
      if (!incomplete) {
        // Day already complete: nothing shows, quiet rollover.
        _armCrossingTimer();
        return;
      }
    }
    _openWindow(
      GraceWindow(
        closingDayStart: closingDayStart,
        boundary: boundary,
        deadline: deadline,
      ),
    );
  }

  void _openWindow(GraceWindow window) {
    _window = window;
    _crossingTimer?.cancel();
    _tickTimer?.cancel();
    _tickTimer = _scheduleOnce(tickInterval, _handleTick);
    notifyListeners();
  }

  void _handleTick() {
    if (_disposed || _window == null) return;
    if (!_clock().isBefore(_window!.deadline)) {
      _endWindow(GraceEndReason.expired);
      return;
    }
    notifyListeners();
    _tickTimer = _scheduleOnce(tickInterval, _handleTick);
  }

  // ── Resolution ───────────────────────────────────────────────

  /// Home's watcher fired the closing day's completion: the day
  /// counted, so grace ends (the celebration/gems flow is the
  /// watcher's own event path, untouched by this call).
  void resolveCompleted() {
    if (_window == null) return;
    _endWindow(GraceEndReason.completed);
  }

  /// A provisionally-opened window (no evaluator at the crossing)
  /// whose closing day turns out to have been complete already:
  /// Home calls this on mount when its evaluation finds the day
  /// complete. Ends the window without any missed-day settlement
  /// consequence — the day was counted in its own day.
  void resolveAlreadyComplete() {
    if (_window == null) return;
    _endWindow(GraceEndReason.alreadyComplete);
  }

  void _endWindow(GraceEndReason reason) {
    final ended = _window;
    if (ended == null) return;
    _window = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    notifyListeners();
    onGraceEnded?.call(reason, ended);
    _armCrossingTimer();
  }

  // ── Lifecycle ────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      // Returning to the foreground: if a window is somehow still
      // live its deadline governs via the tick chain; otherwise
      // (re)arm for the next boundary. A crossing that happened
      // while backgrounded is NOT re-evaluated — nextBoundary is
      // strictly in the future, so no retroactive grace can open.
      if (_window == null) _armCrossingTimer();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Backgrounding mid-grace ends grace (founder spec): the
      // window clears now; settlement proceeds through the normal
      // resume path (Home's recordOpen on the next load/resume).
      if (_window != null) _endWindow(GraceEndReason.backgrounded);
    }
    // `inactive` is transient (system dialogs, call overlays):
    // it neither grants nor ends grace.
  }
}
