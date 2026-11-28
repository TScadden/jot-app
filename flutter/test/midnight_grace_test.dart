import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/midnight_grace.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/summary_completeness.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/tabs_day.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/event_counter_rotator.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/grace_band.dart';
import 'package:tabs_lab/src/features/home/home_checkin_strip.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

import 'test_helpers.dart';

/// Midnight Grace (founder spec, Nov 21, 2026) — the invariant
/// suite. Calendar rule pinned throughout (cutover Nov 1, 2026):
/// the closing day is Nov 5, the boundary is Nov 6 00:00, the
/// grace deadline is Nov 6 00:01:30.
///
/// (a) midnight + incomplete + foreground → grace opens,
///     settlement deferred;
/// (b) completion during grace counts for the CLOSING day,
///     exactly once;
/// (c) expiry → missed-day settlement identical to a no-grace
///     rollover (settled states compared byte-for-byte);
/// (d) midnight + already complete → no grace, normal rollover;
/// (e) closed/backgrounded at midnight → no grace on later open;
/// (f) background mid-grace → grace ends; settlement on next open
///     identical to the no-grace path;
/// (g) grant paths untouched — proven by the existing suites
///     (streak_p0_acceptance, summary_completeness, gems); the
///     grace fire goes through the same watcher event as any
///     completion, pinned in (b).

class _FakeTimer implements Timer {
  bool _active = true;
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

/// A one-shot scheduler that captures callbacks instead of
/// running them; tests fire them by hand after moving the fake
/// clock. Callbacks that reschedule (the tick chain) land back in
/// [pending].
class _FakeScheduler {
  final List<({void Function() cb, _FakeTimer timer})> pending = [];

  Timer schedule(Duration duration, void Function() cb) {
    final timer = _FakeTimer();
    pending.add((cb: cb, timer: timer));
    return timer;
  }

  int get activeCount => pending.where((p) => p.timer.isActive).length;

  /// Fire every currently-active callback once (in schedule
  /// order). Newly scheduled callbacks stay pending.
  void fireActive() {
    final firing = pending.where((p) => p.timer.isActive).toList();
    pending.clear();
    for (final p in firing) {
      p.timer.cancel();
      p.cb();
    }
  }
}

void main() {
  final closingStart = DateTime(2026, 11, 5);
  final boundary = DateTime(2026, 11, 6);
  final deadline = DateTime(2026, 11, 6, 0, 1, 30);

  setUp(() {
    TabsDayBoundary.instance.debugCutoverAt = DateTime(2026, 11, 1);
  });
  tearDown(() {
    TabsDayBoundary.instance.debugCutoverAt = null;
  });

  group('MidnightGraceController', () {
    late DateTime fakeNow;
    late _FakeScheduler scheduler;
    late MidnightGraceController controller;
    late List<GraceEndReason> ended;

    setUp(() {
      fakeNow = DateTime(2026, 11, 5, 23, 59);
      scheduler = _FakeScheduler();
      ended = [];
      controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: scheduler.schedule,
      );
      controller.onGraceEnded = (reason, window) => ended.add(reason);
    });
    tearDown(() => controller.dispose());

    test('(a) crossing + incomplete + foreground opens the window; '
        'settlement is deferred for its whole life', () async {
      controller.closingDayIncompleteEvaluator =
          (start, dl) async => true;
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      await controller.handleCrossingTimerFired();

      expect(controller.isActive, isTrue);
      final window = controller.activeWindow!;
      expect(window.closingDayStart, closingStart);
      expect(window.closingDayStr, '2026-11-05');
      expect(window.boundary, boundary);
      expect(window.deadline, deadline);
      expect(controller.settlementDeferred, isTrue);
      expect(controller.timerText, '1:25');

      // Still deferred one second before the deadline.
      fakeNow = DateTime(2026, 11, 6, 0, 1, 29);
      scheduler.fireActive(); // tick
      expect(controller.isActive, isTrue);
      expect(controller.settlementDeferred, isTrue);
      expect(ended, isEmpty);
    });

    test('timer text: 1:30 at the open, floor seconds down to 0:00',
        () async {
      fakeNow = DateTime(2026, 11, 6, 0, 0, 0);
      await controller.handleCrossingTimerFired();
      expect(controller.timerText, '1:30');
      fakeNow = DateTime(2026, 11, 6, 0, 0, 29);
      expect(controller.timerText, '1:01');
      fakeNow = DateTime(2026, 11, 6, 0, 1, 21);
      expect(controller.timerText, '0:09');
    });

    test('(d) crossing + already complete → no grace at all',
        () async {
      controller.closingDayIncompleteEvaluator =
          (start, dl) async => false;
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isFalse);
      expect(controller.settlementDeferred, isFalse);
      expect(ended, isEmpty);
    });

    test('an evaluator failure grants nothing (normal rollover '
        'governs; settlement is never trapped)', () async {
      controller.closingDayIncompleteEvaluator =
          (start, dl) async => throw StateError('boom');
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isFalse);
      expect(ended, isEmpty);
    });

    test('no evaluator mounted → the window opens provisionally '
        '(spec 5: user on another tab at midnight)', () async {
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isTrue);
      controller.resolveAlreadyComplete();
      expect(controller.isActive, isFalse);
      expect(ended, [GraceEndReason.alreadyComplete]);
    });

    test('(e) backgrounded AT the crossing → no grace; a later '
        'resume never opens it retroactively', () async {
      controller.closingDayIncompleteEvaluator =
          (start, dl) async => true;
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isFalse);

      // Resume at 08:00: only a re-arm for the NEXT boundary.
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      fakeNow = DateTime(2026, 11, 6, 8);
      await controller.handleCrossingTimerFired(); // stale fire
      expect(controller.isActive, isFalse);
      expect(ended, isEmpty);
    });

    test('(e) a stale fire after the would-be deadline (app was '
        'suspended across midnight) grants nothing', () async {
      controller.closingDayIncompleteEvaluator =
          (start, dl) async => true;
      fakeNow = DateTime(2026, 11, 6, 0, 5);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isFalse);
      expect(ended, isEmpty);
    });

    test('expiry ends the window with reason expired and lifts '
        'the settlement gate', () async {
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isTrue);
      fakeNow = DateTime(2026, 11, 6, 0, 1, 30);
      scheduler.fireActive(); // the tick at the deadline
      expect(controller.isActive, isFalse);
      expect(controller.settlementDeferred, isFalse);
      expect(ended, [GraceEndReason.expired]);
    });

    test('(f) backgrounding mid-grace ends the window at once',
        () async {
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isTrue);
      fakeNow = DateTime(2026, 11, 6, 0, 0, 40);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(controller.isActive, isFalse);
      expect(ended, [GraceEndReason.backgrounded]);
      // The window never reopens on resume.
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(controller.isActive, isFalse);
    });

    test('a transient inactive does NOT end grace', () async {
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      await controller.handleCrossingTimerFired();
      controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(controller.isActive, isTrue);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(controller.isActive, isTrue);
    });

    test('resolveCompleted ends the window exactly once', () async {
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      await controller.handleCrossingTimerFired();
      controller.resolveCompleted();
      controller.resolveCompleted();
      expect(controller.isActive, isFalse);
      expect(ended, [GraceEndReason.completed]);
    });

    test('Vera C1 race C: settlementDeferred holds WHILE a crossing '
        'evaluation is in flight (no window exists yet), and a '
        'no-window resolution lifts it', () async {
      final gate = Completer<bool>();
      controller.closingDayIncompleteEvaluator =
          (start, dl) => gate.future;
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      final crossing = controller.handleCrossingTimerFired();
      // Let the crossing reach the evaluator await.
      await Future<void>.delayed(Duration.zero);
      // No window exists yet — but the crossing is unresolved, so
      // the settlement gate must already hold (pre-fix it read
      // false here, and a Home remount in this interval settled
      // the closing day ungated).
      expect(controller.isActive, isFalse);
      expect(controller.settlementDeferred, isTrue);

      gate.complete(false); // day was complete → no window opens
      await crossing;
      expect(controller.isActive, isFalse);
      expect(controller.settlementDeferred, isFalse);
      expect(ended, isEmpty);
    });

    test('Vera C1 race C: an evaluation that opens the window keeps '
        'settlement deferred for the window\'s whole life',
        () async {
      final gate = Completer<bool>();
      controller.closingDayIncompleteEvaluator =
          (start, dl) => gate.future;
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      final crossing = controller.handleCrossingTimerFired();
      await Future<void>.delayed(Duration.zero);
      expect(controller.settlementDeferred, isTrue);

      gate.complete(true); // incomplete → the window opens
      await crossing;
      expect(controller.isActive, isTrue);
      expect(controller.settlementDeferred, isTrue);

      fakeNow = DateTime(2026, 11, 6, 0, 1, 30);
      scheduler.fireActive(); // tick at the deadline → expiry
      expect(controller.isActive, isFalse);
      expect(controller.settlementDeferred, isFalse);
      expect(ended, [GraceEndReason.expired]);
    });
  });

  group('grace completion path (watcher + store)', () {
    const medCat = 8;
    const moodCat = '6';
    const goalsCat = 4;
    const med = SummaryMedication(key: 'k1', name: 'MedA', dose: '5mg');

    late Map<String, String> disk;
    late Map<String, String> markers;
    late StreakStore store;
    late SummaryCompletionWatcher watcher;
    late List<StreakCompletionResult> events;

    Future<bool> push(int c, int b, String j,
            {int? purchasedFreezes}) async =>
        true;

    QuickLogEntry entry({
      required String id,
      required String cat,
      required String body,
      String chips = '[]',
      required DateTime at,
    }) =>
        QuickLogEntry(
          id: id,
          categoryId: cat,
          body: body,
          chips: chips,
          manualText: '',
          timestamp: at.millisecondsSinceEpoch,
        );

    QuickLogEntry checkIn(DateTime at) => entry(
          id: '100',
          cat: moodCat,
          body: 'Feeling: 4/5 Today',
          chips: jsonEncode(const [feelingCheckInTag]),
          at: at,
        );

    SummaryCompletionContext graceContext(List<QuickLogEntry> entries) =>
        SummaryCompletionContext(
          attestedPlan: AttestedPlan(
            plan: buildPlanForFeelingDay(
              feelingDayStart: closingStart,
              medications: const [med],
              reminders: const [],
              habits: const [],
              localState: const TodayPlanLocalState(),
              entries: entries,
              medicationCategoryId: medCat,
              goalsCategoryId: goalsCat,
              evidenceWindowEnd: deadline,
            ),
            attestation: const PlanAttestation(
              medicationsResolved: true,
              remindersResolved: true,
              habitsResolved: true,
            ),
          ),
          entries: entries,
          moodCategoryId: moodCat,
        );

    setUp(() {
      disk = {};
      markers = {};
      events = [];
      store = StreakStore.instance;
      store.debugReset();
      store.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async {
          disk[key] = value;
        },
        delete: (key) async {
          disk.remove(key);
        },
      );
      watcher = SummaryCompletionWatcher(
        store: store,
        onCompletion: (r, s) => events.add(r),
      );
      watcher.debugSetMarkerStore(
        read: (key) async => markers[key],
        write: (key, value) async {
          markers[key] = value;
        },
      );
    });
    tearDown(() => watcher.dispose());

    test('(b) a check-in logged at 00:00:30 completes the CLOSING '
        'day, exactly once', () async {
      final entries = [
        entry(
          id: '1',
          cat: medCat,
          body: 'Took MedA 5mg',
          at: DateTime(2026, 11, 5, 20),
        ),
        checkIn(DateTime(2026, 11, 6, 0, 0, 30)),
      ];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: graceContext(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 0, 45),
        fireableDayStartOverride: closingStart,
        evidenceWindowEnd: deadline,
      );
      expect(fired, isTrue);
      expect(events, hasLength(1));
      expect(store.state!.countedDays, {'2026-11-05'});
      expect(
        markers[SummaryCompletionWatcher.firedDayStorageKey],
        '2026-11-05',
      );

      final again = await watcher.maybeFireSummaryCompletion(
        context: graceContext(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 1, 0),
        fireableDayStartOverride: closingStart,
        evidenceWindowEnd: deadline,
      );
      expect(again, isFalse);
      expect(events, hasLength(1));
      expect(store.state!.countedDays, {'2026-11-05'});
    });

    test('(b) a dose logged INSIDE grace counts toward the closing '
        'day plan (evidence window extension)', () async {
      final entries = [
        checkIn(DateTime(2026, 11, 5, 21)),
        entry(
          id: '1',
          cat: medCat,
          body: 'Took MedA 5mg',
          at: DateTime(2026, 11, 6, 0, 1, 0),
        ),
      ];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: graceContext(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 1, 10),
        fireableDayStartOverride: closingStart,
        evidenceWindowEnd: deadline,
      );
      expect(fired, isTrue);
      expect(store.state!.countedDays, {'2026-11-05'});
    });

    test('evidence AFTER the deadline never counts for the closing '
        'day (grace creates no completion past its window)',
        () async {
      final entries = [
        entry(
          id: '1',
          cat: medCat,
          body: 'Took MedA 5mg',
          at: DateTime(2026, 11, 5, 20),
        ),
        checkIn(DateTime(2026, 11, 6, 0, 1, 31)),
      ];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: graceContext(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 1, 35),
        fireableDayStartOverride: closingStart,
        evidenceWindowEnd: deadline,
      );
      expect(fired, isFalse);
      expect(events, isEmpty);
      expect(store.state?.countedDays ?? const <String>{}, isEmpty);
    });

    test('A8 intact: WITHOUT the grace overrides the closing day '
        'still cannot fire after midnight', () async {
      // Home's pre-grace driving shape: the context is the OPEN
      // day's (Nov 6 — its med is untaken), evaluated at 00:00:45.
      final openDayContext = SummaryCompletionContext(
        attestedPlan: AttestedPlan(
          plan: buildPlanForFeelingDay(
            feelingDayStart: DateTime(2026, 11, 6),
            medications: const [med],
            reminders: const [],
            habits: const [],
            localState: const TodayPlanLocalState(),
            entries: const [],
            medicationCategoryId: medCat,
            goalsCategoryId: goalsCat,
          ),
          attestation: const PlanAttestation(
            medicationsResolved: true,
            remindersResolved: true,
            habitsResolved: true,
          ),
        ),
        entries: [
          entry(
            id: '1',
            cat: medCat,
            body: 'Took MedA 5mg',
            at: DateTime(2026, 11, 5, 20),
          ),
          checkIn(DateTime(2026, 11, 6, 0, 0, 30)),
        ],
        moodCategoryId: moodCat,
      );
      final fired = await watcher.maybeFireSummaryCompletion(
        context: openDayContext,
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 0, 45),
      );
      expect(fired, isFalse);
      expect(store.state?.countedDays ?? const <String>{}, isEmpty);
    });

    test('anti-fabrication holds under grace: no pull + no record '
        '→ no fire, no marker; a later real evaluation fires',
        () async {
      final entries = [
        entry(
          id: '1',
          cat: medCat,
          body: 'Took MedA 5mg',
          at: DateTime(2026, 11, 5, 20),
        ),
        checkIn(DateTime(2026, 11, 6, 0, 0, 30)),
      ];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: graceContext(entries),
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 0, 45),
        fireableDayStartOverride: closingStart,
        evidenceWindowEnd: deadline,
      );
      expect(fired, isFalse);
      expect(markers, isEmpty);

      final later = await watcher.maybeFireSummaryCompletion(
        context: graceContext(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 1, 0),
        fireableDayStartOverride: closingStart,
        evidenceWindowEnd: deadline,
      );
      expect(later, isTrue);
      expect(events, hasLength(1));
    });

    test('(nogems) a grace fire marks the closing day '
        'grace-completed in the settled state (founder, Nov 21, '
        '2026: grace saves the streak, it does not pay)', () async {
      final entries = [
        entry(
          id: '1',
          cat: medCat,
          body: 'Took MedA 5mg',
          at: DateTime(2026, 11, 5, 20),
        ),
        checkIn(DateTime(2026, 11, 6, 0, 0, 30)),
      ];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: graceContext(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 0, 45),
        fireableDayStartOverride: closingStart,
        evidenceWindowEnd: deadline,
      );
      expect(fired, isTrue);
      expect(store.state!.countedDays, {'2026-11-05'},
          reason: 'the streak still counts the closing day');
      expect(store.state!.summaryCompletedDays, {'2026-11-05'});
      expect(store.state!.graceCompletedDays, {'2026-11-05'},
          reason: 'the per-day grace marker the gem suppression '
              'keys off — persisted in the streak blob, so it '
              'survives restarts and sync');
    });

    test('(nogems, Home earn hook) the celebration fires under '
        'grace with NO gem lines and zero grant calls', () async {
      final entries = [
        entry(
          id: '1',
          cat: medCat,
          body: 'Took MedA 5mg',
          at: DateTime(2026, 11, 5, 20),
        ),
        checkIn(DateTime(2026, 11, 6, 0, 0, 30)),
      ];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: graceContext(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: DateTime(2026, 11, 6, 0, 0, 45),
        fireableDayStartOverride: closingStart,
        evidenceWindowEnd: deadline,
      );
      expect(fired, isTrue);
      expect(events, hasLength(1),
          reason: 'the completion event — what Home presents the '
              'celebration from — still fires under grace');

      // Home._presentCompletion's earn hook, verbatim shape: the
      // settled state + the counted (closing) day go into
      // GemService.processCompletion; its lines are the
      // celebration's gem lines.
      final grantCalls = <String>[];
      final gemDisk = <String, String>{};
      final gems = GemService(
        grant: (key) async {
          grantCalls.add(key);
          return (
            statusCode: 200,
            body: {'gemBalance': 5, 'amount': 5, 'alreadyGranted': false},
          );
        },
        spend: (id) async => (statusCode: 400, body: {'error': 'unused'}),
        pullBalance: () async => 0,
      );
      gems.debugSetStore(
        read: (k) async => gemDisk[k],
        write: (k, v) async => gemDisk[k] = v,
        delete: (k) async => gemDisk.remove(k),
      );
      final settled = store.state!;
      final gemResult = await gems.processCompletion(
        summaryTabsDay: '2026-11-05',
        previousStreak: gemSettledStreakBefore(settled, '2026-11-05'),
        newStreak: events.single.newCount,
        settledState: settled,
        now: DateTime(2026, 11, 6, 0, 0, 45),
      );
      expect(grantCalls, isEmpty,
          reason: 'no grant of any kind is requested for a grace '
              'completion');
      expect(gemResult.lines, isEmpty,
          reason: 'the celebration renders gem lines only from '
              'this result — empty means no +5 shows');
      expect(events.single.newCount, 1,
          reason: 'the streak count the celebration celebrates '
              'is unaffected');
    });
  });

  group('settlement equivalence (store level)', () {
    late Map<String, String> disk;
    late StreakStore store;

    Future<bool> push(int c, int b, String j,
            {int? purchasedFreezes}) async =>
        true;

    setUp(() {
      disk = {};
      store = StreakStore.instance;
      store.debugReset();
      store.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async {
          disk[key] = value;
        },
        delete: (key) async {
          disk.remove(key);
        },
      );
    });

    /// A two-day run (Nov 3 + Nov 4 counted); Nov 5 incomplete.
    Future<void> seedRun() async {
      for (final day in [DateTime(2026, 11, 3), DateTime(2026, 11, 4)]) {
        await store.recordSummaryComplete(
          pullSucceeded: true,
          seedCurrent: null,
          seedBest: null,
          seedStateJson: null,
          now: day.add(const Duration(hours: 10)),
          summaryDay: day,
          push: push,
        );
      }
    }

    Future<String> settledJsonAt(DateTime openAt) async {
      final state = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: openAt,
        push: push,
      );
      return jsonEncode(state.toJson());
    }

    test('(c) expiry path: grace lived and expired, then the '
        'ordinary settle — byte-identical to the no-grace rollover',
        () async {
      await seedRun();
      final noGrace = await settledJsonAt(DateTime(2026, 11, 6, 0, 2));

      store.debugReset();
      disk.clear();
      await seedRun();
      // A grace window opens and expires; Home's gate means NO
      // settle call happens inside it. Then the ordinary settle.
      final scheduler = _FakeScheduler();
      var fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      final controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: scheduler.schedule,
      );
      addTearDown(controller.dispose);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isTrue);
      expect(controller.settlementDeferred, isTrue);
      fakeNow = DateTime(2026, 11, 6, 0, 1, 30);
      scheduler.fireActive();
      expect(controller.isActive, isFalse);

      final afterGrace = await settledJsonAt(DateTime(2026, 11, 6, 0, 2));
      expect(afterGrace, noGrace);
      // The missed day settles under the ordinary rules — here the
      // monthly freeze bridges it (the shipped single-missed-day
      // rule), identically on both paths.
      final state = store.state!;
      expect(state.countedDays,
          {'2026-11-03', '2026-11-04', '2026-11-05'});
      expect(state.restoredDays, contains('2026-11-05'));
      expect(state.summaryCompletedDays,
          isNot(contains('2026-11-05')));
      expect(streakCurrent(state, DateTime(2026, 11, 6)), 3);
    });

    test('(f) background mid-grace, next open settles identically '
        'to the no-grace path', () async {
      await seedRun();
      final noGrace = await settledJsonAt(DateTime(2026, 11, 6, 9));

      store.debugReset();
      disk.clear();
      await seedRun();
      final scheduler = _FakeScheduler();
      var fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      final controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: scheduler.schedule,
      );
      addTearDown(controller.dispose);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isTrue);
      fakeNow = DateTime(2026, 11, 6, 0, 0, 40);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(controller.isActive, isFalse);

      final afterBackground = await settledJsonAt(DateTime(2026, 11, 6, 9));
      expect(afterBackground, noGrace);
    });

    test('the hazard the gate exists for: an UNGATED recordOpen '
        'mid-grace settles the closing day THEN — freeze-bridged, '
        'never genuinely completable', () async {
      await seedRun();
      final state = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: DateTime(2026, 11, 6, 0, 0, 45),
        push: push,
      );
      // The day is settled on the spot: the monthly freeze is
      // consumed to bridge it and it lands as a freeze-covered
      // (restored) day — NOT a summary completion. Had grace run
      // its course, the user could have completed the day
      // genuinely inside the window (celebration + gems, freeze
      // unspent). This is exactly what the gate defers.
      expect(state.lastEvaluatedDay, '2026-11-06');
      expect(state.restoredDays, contains('2026-11-05'));
      expect(state.summaryCompletedDays,
          isNot(contains('2026-11-05')));
    });
  });

  _registerBandWidgetTests();
  _registerVeraRaceWidgetTests();
}

// ── Widget-level pins: the band element and Home's tenancy ─────

class _FakeHc extends HealthConnectService {
  @override
  Future<HcAvailability> probeAvailability() async => const HcAvailability(
        serviceAvailable: true,
        grantedPermissions: HealthConnectService.requiredPermissions,
        bridgeErrorCode: null,
        stepsProbe: HcReadProbeOutcome.ok,
        persistedConnected: true,
      );

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    final now = DateTime.now();
    final noon = DateTime(now.year, now.month, now.day, 12);
    return [HrSample(timeMs: noon.millisecondsSinceEpoch, bpm: 74)];
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async => 159;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => 510;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async =>
      const [];
}

MockClient _mockWeather() => MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
      }
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
          200);
    });

/// The band-tenancy fixture backend. The profile deliberately
/// OMITS the medications/reminders keys: the closing day's plan is
/// then unattested, so no evaluation can fire it complete inside
/// the harness (the day reads incomplete — grace's eligibility
/// answer — and the watcher stays silent). One event counter makes
/// the counters the band's would-be tenant.
MockClient _mockBandBackend({required bool closingDayCheckedIn}) {
  final checkInTs =
      DateTime(2026, 11, 5, 21).millisecondsSinceEpoch;
  final entries = <Map<String, dynamic>>[
    if (closingDayCheckedIn)
      {
        'id': 200,
        'categoryId': 6,
        'body': 'Feeling: 3/5 Today',
        'chips': '["Daily Ranking"]',
        'manualText': '',
        'timestamp': checkInTs,
      },
  ];
  final counters = [
    {
      'id': 'c1',
      'name': 'Trip',
      'targetDate':
          DateTime(2026, 12, 25).millisecondsSinceEpoch,
      'isUp': true,
      'autoUp': false,
      'isFavorite': false,
      'isArchived': false,
      'deletedAt': null,
    },
  ];
  return MockClient((request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(
        jsonEncode({
          'entries': entries,
          'categories': [
            {'id': 1, 'name': 'Symptoms'},
            {'id': 4, 'name': 'Goals & Habits'},
            {'id': 6, 'name': 'Mood & Energy'},
            {'id': 8, 'name': 'Medication'},
          ],
          'profile': {
            'currentStreak': 2,
            'bestStreak': 2,
            'eventCounters': jsonEncode(counters),
          },
          'isUnlimited': true,
          'isAdmin': false,
        }),
        200,
      );
    }
    if (request.url.path == '/api/habits') {
      return http.Response('{"habits":[]}', 200);
    }
    if (request.url.path == '/api/sync/entries') {
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  });
}

Future<void> _bridgeHome(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
  }
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 31));
}

void _registerBandWidgetTests() {
  group('MidnightGraceBand widget', () {
    testWidgets('renders timer + Grace, ticks down, fades out on '
        'expiry and reports completion of the fade', (tester) async {
      var fakeNow = DateTime(2026, 11, 6, 0, 0, 10);
      final scheduler = _FakeScheduler();
      final controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: scheduler.schedule,
      );
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isTrue);

      var fadeOutDone = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MidnightGraceBand(
              controller: controller,
              onFadeOutComplete: () => fadeOutDone = true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('1:20'), findsOneWidget);
      expect(find.text('Grace'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('midnight_grace_band')),
        findsOneWidget,
      );

      fakeNow = DateTime(2026, 11, 6, 0, 1, 0);
      scheduler.fireActive(); // tick
      await tester.pump();
      expect(find.text('0:30'), findsOneWidget);

      fakeNow = DateTime(2026, 11, 6, 0, 1, 30);
      scheduler.fireActive(); // tick at the deadline → expiry
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(fadeOutDone, isTrue);
      expect(find.text('Grace'), findsNothing);
    });
  });

  group('Home band tenancy under grace', () {
    setUp(() {
      TabsDayBoundary.instance.debugCutoverAt = DateTime(2026, 11, 1);
      TabsBackend.debugResetSharedCaches();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
      final disk = <String, String>{};
      LogEntryOutbox.instance.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async {
          disk[k] = v;
        },
        delete: (k) async {
          disk.remove(k);
        },
      );
      LogEntryOutbox.instance.debugReset();
    });
    tearDown(() {
      TabsDayBoundary.instance.debugCutoverAt = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
    });

    Future<MidnightGraceController> openGrace() async {
      final fakeNow = DateTime(2026, 11, 6, 0, 0, 10);
      final controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: _FakeScheduler().schedule,
      );
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isTrue);
      return controller;
    }

    Future<void> pumpHome(
      WidgetTester tester, {
      required bool closingDayCheckedIn,
      required MidnightGraceController controller,
    }) async {
      final backend = TabsBackend(
        client: _mockBandBackend(closingDayCheckedIn: closingDayCheckedIn),
        sessionStore: FakeSessionStore()..token = 'tok',
      );
      final scoreStore = HealthHistoryStore.testInstance();
      final disk = <String, String>{};
      scoreStore.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async {
          disk[k] = v;
        },
        delete: (k) async {
          disk.remove(k);
        },
      );
      scoreStore.debugReset();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: HomeScreen(
              weatherApi: WeatherApiClient(client: _mockWeather()),
              tabsBackend: backend,
              logEntryOutbox: LogEntryOutbox.instance,
              healthConnectService: _FakeHc(),
              healthRepository:
                  HealthRepository(hc: _FakeHc(), backend: backend),
              healthHistoryStore: scoreStore,
              dailyScoreSnapshotCapture: ({bool force = false}) async => true,
              graceController: controller,
            ),
          ),
        ),
      );
      await _bridgeHome(tester);
    }

    testWidgets('counters tenant (mock state): the grace element '
        'REPLACES the event counters', (tester) async {
      final controller = await openGrace();
      await pumpHome(
        tester,
        closingDayCheckedIn: true,
        controller: controller,
      );
      expect(find.byType(MidnightGraceBand), findsOneWidget);
      expect(find.text('Grace'), findsOneWidget);
      expect(find.text('1:20'), findsOneWidget);
      expect(find.byType(EventCounterRotator), findsNothing);
      expect(find.byType(HomeCheckInStrip), findsNothing);
    });

    testWidgets('strip tenant: the grace element stacks ABOVE the '
        'check-in strip, which stays in the tree (tappable)',
        (tester) async {
      final controller = await openGrace();
      await pumpHome(
        tester,
        closingDayCheckedIn: false,
        controller: controller,
      );
      expect(find.byType(MidnightGraceBand), findsOneWidget);
      expect(find.byType(HomeCheckInStrip), findsOneWidget);
      final bandY =
          tester.getCenter(find.byType(MidnightGraceBand)).dy;
      final stripY =
          tester.getCenter(find.byType(HomeCheckInStrip)).dy;
      expect(bandY, lessThan(stripY));
    });
  });
}

// ── Vera condition races (Nov 21, 2026 delta) ──────────────────
//
// C1 and C2 are TOCTOU races: the production code paths are
// Home's settle and Home's completion evaluation, so these tests
// drive real HomeScreen instances with a HealthRepository whose
// streak-record pull can be parked on a completer — the delayed
// pull / delayed resolution IS the race, and on the pre-fix head
// every test below fails (the ungated recordOpen lands, or the
// stale evaluation fires the closing day after its window ended).

/// A HealthRepository whose streak-record pull parks while the
/// gate is closed. Every other repository behavior is the real
/// one (vitals, streak counters, gem balance ride the mock
/// backend); only loadStreakRecord is gated, and pushes count.
class _GatedHealthRepository extends HealthRepository {
  _GatedHealthRepository({required super.hc, required super.backend});

  Completer<void>? _gate;
  int pushCalls = 0;

  void closeGate() => _gate = Completer<void>();

  void openGate() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<
      ({
        bool succeeded,
        int? current,
        int? best,
        String? stateJson,
        int? purchasedFreezes
      })> loadStreakRecord() async {
    final gate = _gate;
    if (gate != null) await gate.future;
    return (
      succeeded: true,
      current: 2,
      best: 2,
      stateJson: null,
      purchasedFreezes: null,
    );
  }

  @override
  Future<bool> pushStreakRecord(int current, int best, String stateJson,
      {int? purchasedFreezes}) async {
    pushCalls++;
    return true;
  }
}

/// The C2 fixture backend: an ATTESTED plan-free profile
/// (medications/reminders present and empty) and the closing
/// day's feeling check-in already logged — so the closing day IS
/// complete the moment an evaluation resolves its inputs, and any
/// evaluation that fires under the grace overrides counts
/// '2026-11-05'.
MockClient _mockGraceFireBackend() {
  final entries = <Map<String, dynamic>>[
    {
      'id': 200,
      'categoryId': 6,
      'body': 'Feeling: 3/5 Today',
      'chips': '["Daily Ranking"]',
      'manualText': '',
      'timestamp': DateTime(2026, 11, 5, 21).millisecondsSinceEpoch,
    },
  ];
  return MockClient((request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(
        jsonEncode({
          'entries': entries,
          'categories': [
            {'id': 1, 'name': 'Symptoms'},
            {'id': 4, 'name': 'Goals & Habits'},
            {'id': 6, 'name': 'Mood & Energy'},
            {'id': 8, 'name': 'Medication'},
          ],
          'profile': {
            'currentStreak': 2,
            'bestStreak': 2,
            'medications': <dynamic>[],
            'reminders': <dynamic>[],
          },
          'isUnlimited': true,
          'isAdmin': false,
        }),
        200,
      );
    }
    if (request.url.path == '/api/habits') {
      return http.Response('{"habits":[]}', 200);
    }
    if (request.url.path == '/api/sync/entries') {
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  });
}

TabsBackend _backendFor(MockClient client) => TabsBackend(
      client: client,
      sessionStore: FakeSessionStore()..token = 'tok',
    );

/// Let real-async work (mock HTTP, storage, the gated pull's
/// release) progress between widget pumps.
Future<void> _pumpReal(WidgetTester tester, {int rounds = 15}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _registerVeraRaceWidgetTests() {
  group('Vera condition races (Home level)', () {
    late Map<String, String> streakDisk;

    setUp(() {
      TabsDayBoundary.instance.debugCutoverAt = DateTime(2026, 11, 1);
      TabsBackend.debugResetSharedCaches();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
      final disk = <String, String>{};
      LogEntryOutbox.instance.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async {
          disk[k] = v;
        },
        delete: (k) async {
          disk.remove(k);
        },
      );
      LogEntryOutbox.instance.debugReset();
      streakDisk = <String, String>{};
      StreakStore.instance.debugReset();
      StreakStore.instance.debugSetStore(
        read: (k) async => streakDisk[k],
        write: (k, v) async {
          streakDisk[k] = v;
        },
        delete: (k) async {
          streakDisk.remove(k);
        },
      );
    });
    tearDown(() {
      TabsDayBoundary.instance.debugCutoverAt = null;
      StreakStore.instance.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
    });

    Future<void> pumpRaceHome(
      WidgetTester tester, {
      required Key key,
      required MidnightGraceController controller,
      required TabsBackend backend,
      required HealthRepository repo,
    }) async {
      final scoreStore = HealthHistoryStore.testInstance();
      final disk = <String, String>{};
      scoreStore.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async {
          disk[k] = v;
        },
        delete: (k) async {
          disk.remove(k);
        },
      );
      scoreStore.debugReset();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: HomeScreen(
              key: key,
              weatherApi: WeatherApiClient(client: _mockWeather()),
              tabsBackend: backend,
              logEntryOutbox: LogEntryOutbox.instance,
              healthConnectService: _FakeHc(),
              healthRepository: repo,
              healthHistoryStore: scoreStore,
              dailyScoreSnapshotCapture: ({bool force = false}) async =>
                  true,
              graceController: controller,
            ),
          ),
        ),
      );
      await _bridgeHome(tester);
    }

    testWidgets(
        'Vera C1 race A: a settle whose streak-record pull is '
        'delayed across the boundary does NOT recordOpen while '
        'grace is active — and settles normally once grace ends',
        (tester) async {
      var fakeNow = DateTime(2026, 11, 5, 23, 59, 50);
      final scheduler = _FakeScheduler();
      final controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: scheduler.schedule,
      );
      addTearDown(controller.dispose);
      final backend = _backendFor(
          _mockBandBackend(closingDayCheckedIn: true));
      final repo =
          _GatedHealthRepository(hc: _FakeHc(), backend: backend);
      repo.closeGate();

      // Home loads BEFORE midnight; its settle starts and parks
      // on the gated pull (gate check passed: no window yet).
      await pumpRaceHome(
        tester,
        key: const ValueKey('c1a'),
        controller: controller,
        backend: backend,
        repo: repo,
      );
      expect(StreakStore.instance.state, isNull);

      // Midnight crosses; the controller's crossing evaluation
      // (Home's own evaluator) also parks on the gated pull.
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      final crossing = controller.handleCrossingTimerFired();
      await _pumpReal(tester, rounds: 3);

      // The pull lands AFTER midnight — the window opens around
      // the in-flight settle.
      repo.openGate();
      await crossing;
      await _pumpReal(tester);
      expect(controller.isActive, isTrue);
      // The in-flight settle must NOT have run recordOpen: the
      // store is still uninstalled (pre-fix it settled here,
      // freeze-bridging the closing day mid-grace).
      expect(StreakStore.instance.state, isNull);

      // Grace expires: the grace-end handler re-runs the settle
      // and recordOpen lands normally.
      fakeNow = DateTime(2026, 11, 6, 0, 1, 30);
      scheduler.fireActive();
      expect(controller.isActive, isFalse);
      await _pumpReal(tester);
      expect(StreakStore.instance.state, isNotNull);
      expect(StreakStore.instance.state!.seeded, isTrue);
    });

    testWidgets(
        'Vera C1 race C: a Home remount DURING crossing evaluation '
        'defers its settle, which then proceeds when the crossing '
        'resolves with NO window (day was complete)',
        (tester) async {
      var fakeNow = DateTime(2026, 11, 5, 23, 59);
      final scheduler = _FakeScheduler();
      final controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: scheduler.schedule,
      );
      addTearDown(controller.dispose);
      final backend = _backendFor(
          _mockBandBackend(closingDayCheckedIn: true));
      final repo =
          _GatedHealthRepository(hc: _FakeHc(), backend: backend);

      // First Home: its load settle lands (baseline).
      await pumpRaceHome(
        tester,
        key: const ValueKey('c1c-first'),
        controller: controller,
        backend: backend,
        repo: repo,
      );
      expect(StreakStore.instance.state, isNotNull);

      // Reset the store so the REMOUNT's settle is observable,
      // then start a crossing whose evaluator parks.
      StreakStore.instance.debugReset();
      streakDisk.clear();
      final evaluatorGate = Completer<bool>();
      controller.closingDayIncompleteEvaluator =
          (start, dl) => evaluatorGate.future;
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      final crossing = controller.handleCrossingTimerFired();
      await _pumpReal(tester, rounds: 3);
      expect(controller.isActive, isFalse);
      expect(controller.settlementDeferred, isTrue);

      // The remount (the spec-5 user switching to Home at
      // midnight): its load settle runs DURING the evaluation.
      final backend2 = _backendFor(
          _mockBandBackend(closingDayCheckedIn: true));
      await pumpRaceHome(
        tester,
        key: const ValueKey('c1c-second'),
        controller: controller,
        backend: backend2,
        repo: repo,
      );
      // Deferred — NOT settled ungated in the evaluation interval
      // (pre-fix, recordOpen landed here).
      expect(StreakStore.instance.state, isNull);

      // The crossing resolves: day was complete, no window opens.
      // The deferred settle must self-heal and land.
      evaluatorGate.complete(false);
      await crossing;
      expect(controller.isActive, isFalse);
      await _pumpReal(tester);
      expect(StreakStore.instance.state, isNotNull);
      expect(StreakStore.instance.state!.seeded, isTrue);
    });

    testWidgets(
        'Vera C1 race C: a Home remount DURING crossing evaluation '
        'defers its settle; when the evaluation OPENs the window '
        'the settle stays deferred until grace ends, then lands',
        (tester) async {
      var fakeNow = DateTime(2026, 11, 5, 23, 59);
      final scheduler = _FakeScheduler();
      final controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: scheduler.schedule,
      );
      addTearDown(controller.dispose);
      final backend = _backendFor(
          _mockBandBackend(closingDayCheckedIn: true));
      final repo =
          _GatedHealthRepository(hc: _FakeHc(), backend: backend);

      await pumpRaceHome(
        tester,
        key: const ValueKey('c1c2-first'),
        controller: controller,
        backend: backend,
        repo: repo,
      );
      expect(StreakStore.instance.state, isNotNull);

      StreakStore.instance.debugReset();
      streakDisk.clear();
      final evaluatorGate = Completer<bool>();
      controller.closingDayIncompleteEvaluator =
          (start, dl) => evaluatorGate.future;
      fakeNow = DateTime(2026, 11, 6, 0, 0, 5);
      final crossing = controller.handleCrossingTimerFired();
      await _pumpReal(tester, rounds: 3);
      expect(controller.settlementDeferred, isTrue);

      final backend2 = _backendFor(
          _mockBandBackend(closingDayCheckedIn: true));
      await pumpRaceHome(
        tester,
        key: const ValueKey('c1c2-second'),
        controller: controller,
        backend: backend2,
        repo: repo,
      );
      expect(StreakStore.instance.state, isNull);

      // The evaluation opens the window: the waiting settle
      // observes the live window and stays deferred.
      evaluatorGate.complete(true);
      await crossing;
      await _pumpReal(tester);
      expect(controller.isActive, isTrue);
      expect(StreakStore.instance.state, isNull);

      // Grace expires → the grace-end settle lands normally.
      fakeNow = DateTime(2026, 11, 6, 0, 1, 30);
      scheduler.fireActive();
      expect(controller.isActive, isFalse);
      await _pumpReal(tester);
      expect(StreakStore.instance.state, isNotNull);
      expect(StreakStore.instance.state!.seeded, isTrue);
    });

    testWidgets(
        'Vera C2: an evaluation whose input resolution lands AFTER '
        'expiry does NOT fire the closing day (no counted day, no '
        'summary-completed mark)', (tester) async {
      var fakeNow = DateTime(2026, 11, 6, 0, 0, 10);
      final scheduler = _FakeScheduler();
      final controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: scheduler.schedule,
      );
      addTearDown(controller.dispose);
      // No evaluator mounted yet → the window opens provisionally.
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isTrue);

      final backend = _backendFor(_mockGraceFireBackend());
      final repo =
          _GatedHealthRepository(hc: _FakeHc(), backend: backend);
      repo.closeGate();
      await pumpRaceHome(
        tester,
        key: const ValueKey('c2-expiry'),
        controller: controller,
        backend: backend,
        repo: repo,
      );

      // Trigger the firing evaluation (the app-resume trigger):
      // it captures the live window, then its input resolution
      // parks on the gated pull.
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pumpReal(tester, rounds: 5);

      // The window EXPIRES while resolution is in flight; the
      // grace-end handler re-runs settlement (also parked on the
      // gate).
      fakeNow = DateTime(2026, 11, 6, 0, 1, 30);
      scheduler.fireActive();
      expect(controller.isActive, isFalse);

      // Resolution lands — after the window ended. The stale
      // evaluation must NOT fire the closing day (pre-fix it did:
      // a completion created after the window).
      repo.openGate();
      await _pumpReal(tester, rounds: 20);
      final state = StreakStore.instance.state;
      expect(state?.countedDays ?? const <String>{},
          isNot(contains('2026-11-05')));
      expect(state?.summaryCompletedDays ?? const <String>{},
          isNot(contains('2026-11-05')));
    });

    testWidgets(
        'Vera C2: an evaluation whose input resolution lands AFTER '
        'a background-end does NOT fire the closing day',
        (tester) async {
      final fakeNow = DateTime(2026, 11, 6, 0, 0, 10);
      final scheduler = _FakeScheduler();
      final controller = MidnightGraceController(
        clock: () => fakeNow,
        scheduleOnce: scheduler.schedule,
      );
      addTearDown(controller.dispose);
      await controller.handleCrossingTimerFired();
      expect(controller.isActive, isTrue);

      final backend = _backendFor(_mockGraceFireBackend());
      final repo =
          _GatedHealthRepository(hc: _FakeHc(), backend: backend);
      repo.closeGate();
      await pumpRaceHome(
        tester,
        key: const ValueKey('c2-background'),
        controller: controller,
        backend: backend,
        repo: repo,
      );

      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pumpReal(tester, rounds: 5);

      // Backgrounding ends the window mid-resolution.
      controller
          .didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(controller.isActive, isFalse);

      repo.openGate();
      await _pumpReal(tester, rounds: 20);
      final state = StreakStore.instance.state;
      expect(state?.countedDays ?? const <String>{},
          isNot(contains('2026-11-05')));
      expect(state?.summaryCompletedDays ?? const <String>{},
          isNot(contains('2026-11-05')));
    });
  });
}
