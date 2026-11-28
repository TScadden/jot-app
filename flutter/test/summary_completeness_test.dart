import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/summary_completeness.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';

/// Summary completeness (D11 + Vera's two binding conditions):
/// plan RESOLVED (never a default) + nothing remaining under the
/// ONE resolved definition (founder ruling, Nov 25, 2026: a
/// deliberately skipped dose DOES resolve its item for completion
/// counting) + the feeling check-in; firing is open-day only,
/// exactly once.
void main() {
  const medCat = 8;
  const moodCat = '6';
  const goalsCat = 4;

  // The Nov 5 feeling day: [Nov 5 04:00, Nov 6 04:00).
  final dayStart = DateTime(2026, 11, 5, 4);
  DateTime onNov5(int h) => DateTime(2026, 11, 5, h);
  DateTime onNov6(int h) => DateTime(2026, 11, 6, h);

  QuickLogEntry entry({
    required String id,
    required String cat,
    required String body,
    String chips = '[]',
    required DateTime at,
  }) => QuickLogEntry(
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

  const med = SummaryMedication(key: 'k1', name: 'MedA', dose: '5mg');

  TodayPlanData planFor(
    List<QuickLogEntry> entries, {
    List<SummaryMedication> meds = const [],
  }) => buildPlanForFeelingDay(
    feelingDayStart: dayStart,
    medications: meds,
    reminders: const [],
    habits: const [],
    localState: const TodayPlanLocalState(),
    entries: entries,
    medicationCategoryId: medCat,
    goalsCategoryId: goalsCat,
  );

  // P0 adaptation (Bram, flagged for Vera): the attestation API
  // replaced the plan + planResolved pair — the plan value now
  // carries its resolved-ness (AttestedPlan). `resolved: false`
  // maps to a fully unresolved attestation; a null plan maps to
  // no attested plan at all. Assertions unchanged.
  bool complete({
    required TodayPlanData? plan,
    required bool resolved,
    required List<QuickLogEntry> entries,
  }) => isSummaryComplete(
    feelingDayStart: dayStart,
    attestedPlan: plan == null
        ? null
        : AttestedPlan(
            plan: plan,
            attestation: resolved
                ? const PlanAttestation(
                    medicationsResolved: true,
                    remindersResolved: true,
                    habitsResolved: true,
                  )
                : const PlanAttestation.unresolved(),
          ),
    entries: entries,
    moodCategoryId: moodCat,
  );

  group('isSummaryComplete (D11)', () {
    test('Vera condition 1: an UNRESOLVED plan can never read as '
        'plannedCount == 0 complete', () {
      final entries = [checkIn(onNov5(9))];
      expect(
        complete(plan: TodayPlanData.empty, resolved: false, entries: entries),
        isFalse,
      );
      expect(complete(plan: null, resolved: true, entries: entries), isFalse);
    });

    test('plannedCount == 0 (authoritative) + check-in = complete', () {
      final entries = [checkIn(onNov5(9))];
      final plan = planFor(entries);
      expect(plan.plannedCount, 0);
      expect(complete(plan: plan, resolved: true, entries: entries), isTrue);
    });

    test('plannedCount == 0 without the check-in is NOT complete', () {
      final plan = planFor(const []);
      expect(complete(plan: plan, resolved: true, entries: const []), isFalse);
    });

    test('everything taken + check-in = complete', () {
      final entries = [
        entry(id: '1', cat: medCat, body: 'Took MedA 5mg', at: onNov5(8)),
        checkIn(onNov5(9)),
      ];
      final plan = planFor(entries, meds: const [med]);
      expect(plan.remainingCount, 0);
      expect(complete(plan: plan, resolved: true, entries: entries), isTrue);
    });

    test('a SKIPPED dose resolves the day with check-in (founder '
        'ruling, Nov 25, 2026: a deliberately skipped dose counts '
        'as completed for completion counting)', () {
      final entries = [
        entry(
          id: '1',
          cat: medCat,
          body: '[Corrected to Skipped] Took MedA 5mg',
          at: onNov5(8),
        ),
        checkIn(onNov5(9)),
      ];
      final plan = planFor(entries, meds: const [med]);
      expect(plan.remainingCount, 0);
      expect(complete(plan: plan, resolved: true, entries: entries), isTrue);
      // Per-item records unchanged: the dose still reads skipped,
      // never taken — only the completion count moved.
      expect(plan.items, isEmpty); // resolved items do not render
      expect(
        medSkippedFromEntries(
          medName: 'MedA',
          todayEntries: entries,
          medicationCategoryId: medCat,
        ),
        isTrue,
      );
      expect(
        medTakenFromEntries(
          medName: 'MedA',
          todayEntries: entries,
          medicationCategoryId: medCat,
        ),
        isFalse,
      );
    });

    test('a SKIPPED dose WITHOUT the check-in is still NOT '
        'complete (the ruling keeps the check-in term)', () {
      final entries = [
        entry(
          id: '1',
          cat: medCat,
          body: '[Corrected to Skipped] Took MedA 5mg',
          at: onNov5(8),
        ),
      ];
      final plan = planFor(entries, meds: const [med]);
      expect(plan.remainingCount, 0);
      expect(complete(plan: plan, resolved: true, entries: entries), isFalse);
    });

    test('an untaken dose blocks completion', () {
      final entries = [checkIn(onNov5(9))];
      final plan = planFor(entries, meds: const [med]);
      expect(plan.remainingCount, 1);
      expect(complete(plan: plan, resolved: true, entries: entries), isFalse);
    });

    test('evidence window: a dose taken at 01:00 on the NEXT '
        'calendar date is inside the feeling window and counts', () {
      final entries = [
        entry(id: '1', cat: medCat, body: 'Took MedA 5mg', at: onNov6(1)),
        checkIn(onNov5(9)),
      ];
      final plan = planFor(entries, meds: const [med]);
      expect(plan.remainingCount, 0);
      expect(complete(plan: plan, resolved: true, entries: entries), isTrue);
    });

    test('evidence window: a dose taken at 01:00 on the plan date '
        'is BEFORE the window opened and does not count', () {
      final entries = [
        entry(id: '1', cat: medCat, body: 'Took MedA 5mg', at: onNov5(1)),
        checkIn(onNov5(9)),
      ];
      final plan = planFor(entries, meds: const [med]);
      expect(plan.remainingCount, 1);
      expect(complete(plan: plan, resolved: true, entries: entries), isFalse);
    });

    test('a check-in logged at 02:00 the next calendar date '
        'belongs to this feeling day', () {
      final entries = [checkIn(onNov6(2))];
      final plan = planFor(entries);
      expect(complete(plan: plan, resolved: true, entries: entries), isTrue);
    });
  });

  group('SummaryCompletionWatcher', () {
    late Map<String, String> disk;
    late Map<String, String> markers;
    late StreakStore store;
    late SummaryCompletionWatcher watcher;
    late List<StreakCompletionResult> events;

    Future<bool> push(int c, int b, String j, {int? purchasedFreezes}) async =>
        true;

    SummaryCompletionContext ctxFor(
      List<QuickLogEntry> entries, {
      DateTime? start,
      List<SummaryMedication> meds = const [],
    }) => SummaryCompletionContext(
      // P0 adaptation (flagged): fully-attested plan wrapper.
      attestedPlan: AttestedPlan(
        plan: buildPlanForFeelingDay(
          feelingDayStart: start ?? dayStart,
          medications: meds,
          reminders: const [],
          habits: const [],
          localState: const TodayPlanLocalState(),
          entries: entries,
          medicationCategoryId: medCat,
          goalsCategoryId: goalsCat,
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

    tearDown(() {
      watcher.dispose();
    });

    test('fires exactly once for the open day: the first complete '
        'evaluation records the day and emits; later calls do not', () async {
      final entries = [checkIn(onNov5(9))];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: ctxFor(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: onNov5(10),
      );
      expect(fired, isTrue);
      expect(events, hasLength(1));
      expect(events.single.newCount, 1);
      expect(store.state!.countedDays, {'2026-11-05'});
      expect(
        markers[SummaryCompletionWatcher.firedDayStorageKey],
        '2026-11-05',
      );

      final again = await watcher.maybeFireSummaryCompletion(
        context: ctxFor(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: onNov5(11),
      );
      expect(again, isFalse);
      expect(events, hasLength(1));
    });

    test('a skip-completed day fires exactly once (the YAY path): '
        'the skipped dose resolves the plan, the watcher records '
        'the day and emits one completion', () async {
      final entries = [
        entry(
          id: '1',
          cat: medCat,
          body: '[Corrected to Skipped] Took MedA 5mg',
          at: onNov5(8),
        ),
        checkIn(onNov5(9)),
      ];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: ctxFor(entries, meds: const [med]),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: onNov5(10),
      );
      expect(fired, isTrue);
      expect(events, hasLength(1));
      expect(events.single.newCount, 1);
      expect(store.state!.countedDays, {'2026-11-05'});
      expect(store.state!.summaryCompletedDays, {'2026-11-05'});

      final again = await watcher.maybeFireSummaryCompletion(
        context: ctxFor(entries, meds: const [med]),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: onNov5(11),
      );
      expect(again, isFalse);
      expect(events, hasLength(1));
    });

    test('incomplete summary: nothing fires, no marker', () async {
      final fired = await watcher.maybeFireSummaryCompletion(
        context: ctxFor(const []),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: onNov5(10),
      );
      expect(fired, isFalse);
      expect(events, isEmpty);
      expect(markers, isEmpty);
    });

    test('anti-fabrication: complete summary but no pull and no '
        'record — nothing fires and NO marker is written, so a '
        'later call with a record can still fire', () async {
      final entries = [checkIn(onNov5(9))];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: ctxFor(entries),
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: onNov5(10),
      );
      expect(fired, isFalse);
      expect(markers, isEmpty);
      expect(store.state, isNull);

      final later = await watcher.maybeFireSummaryCompletion(
        context: ctxFor(entries),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: onNov5(11),
      );
      expect(later, isTrue);
      expect(events, hasLength(1));
    });

    test('Vera condition 2: a CLOSED day never fires — evidence '
        'for yesterday\'s feeling day, evaluated today, completes '
        'nothing', () async {
      // The only check-in belongs to the Nov 5 feeling day; at
      // Nov 6 noon the open feeling day is Nov 6, which has no
      // check-in. The backfilled/late evaluation must not
      // retro-fire Nov 5 (A8).
      final entries = [checkIn(onNov5(9))];
      final fired = await watcher.maybeFireSummaryCompletion(
        context: ctxFor(entries, start: DateTime(2026, 11, 6, 4)),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: onNov6(12),
      );
      expect(fired, isFalse);
      expect(events, isEmpty);
      expect(store.state?.countedDays ?? const <String>{}, isEmpty);
    });
  });
}
