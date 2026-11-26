import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/summary_completeness.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';

/// Bounded re-settlement (skip-counts-complete, Nov 25, 2026):
/// the one-shot predicate-transition heal. The fixture mirrors
/// the founder's real Nov 25 evidence shape: 5 meds (4 taken +
/// Desvenlafaxine Succinate ER 100mg deliberately skipped),
/// reminder + habit completed, check-in ranking 1 recorded — a
/// day that was skip-only-incomplete under the taken-only rule
/// and is complete under the resolved rule.
void main() {
  const medCat = 8;
  const moodCat = 6;
  const goalsCat = 4;

  const founderMeds = [
    SummaryMedication(key: 'iva', name: 'Ivabradine', dose: '7.5 mg'),
    SummaryMedication(key: 'bpc', name: 'BPC-157', dose: '0.05'),
    SummaryMedication(key: 'ss31', name: 'SS-31', dose: '0.05'),
    SummaryMedication(key: 'mots', name: 'MOTS-c', dose: '0.10'),
    SummaryMedication(
      key: 'desv',
      name: 'Desvenlafaxine Succinate ER',
      dose: '100mg',
    ),
  ];
  const founderReminders = [
    SummaryReminder(
      id: 1,
      title: 'Salt pills',
      fixedHour: 12,
      fixedMinute: 0,
      isEnabled: true,
    ),
  ];
  const founderHabits = [
    HabitDto(id: 'h1', title: 'Physical therapy exercises', logs: []),
  ];

  QuickLogEntry entry({
    required int id,
    required int cat,
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

  DateTime onNov25(int h, [int m = 0]) => DateTime(2026, 11, 25, h, m);

  List<QuickLogEntry> founderEntries({bool withCheckIn = true}) => [
    entry(id: 1, cat: medCat, body: 'Took Ivabradine 7.5 mg', at: onNov25(8)),
    entry(id: 2, cat: medCat, body: 'Took BPC-157 0.05', at: onNov25(8, 1)),
    entry(id: 3, cat: medCat, body: 'Took SS-31 0.05', at: onNov25(8, 2)),
    entry(id: 4, cat: medCat, body: 'Took MOTS-c 0.10', at: onNov25(8, 3)),
    entry(
      id: 5,
      cat: medCat,
      body: '[Corrected to Skipped] Took Desvenlafaxine Succinate ER 100mg',
      at: onNov25(21, 30),
    ),
    entry(
      id: 6,
      cat: goalsCat,
      body: 'Completed reminder: Salt pills',
      at: onNov25(12),
    ),
    entry(
      id: 7,
      cat: goalsCat,
      body: 'Completed habit: Physical therapy exercises',
      at: onNov25(12, 5),
    ),
    if (withCheckIn)
      entry(
        id: 8,
        cat: moodCat,
        body: 'Feeling: 1/5 Today',
        chips: jsonEncode(const [feelingCheckInTag]),
        at: onNov25(22),
      ),
  ];

  SummaryCompletionContext contextFor(
    DateTime dayStart, {
    required List<QuickLogEntry> entries,
    bool attested = true,
  }) => SummaryCompletionContext(
    attestedPlan: AttestedPlan(
      plan: buildPlanForFeelingDay(
        feelingDayStart: dayStart,
        medications: founderMeds,
        reminders: founderReminders,
        habits: founderHabits,
        localState: const TodayPlanLocalState(),
        entries: entries,
        medicationCategoryId: medCat,
        goalsCategoryId: goalsCat,
      ),
      attestation: attested
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

  /// Length of the consecutive counted run ending on [day].
  /// (streakCurrent anchored on Nov 26 reads 0 before the heal by
  /// design — Nov 24 is neither today nor yesterday — so the +1
  /// is measured on the runs ending at the boundary days.)
  int runEndingAt(StreakState s, String day) {
    var n = 0;
    var d = DateTime.parse(day);
    while (s.countedDays.contains(streakDayStr(d))) {
      n++;
      d = d.subtract(const Duration(days: 1));
    }
    return n;
  }

  Set<String> runEnding(String end, int n) {
    final out = <String>{};
    var d = DateTime.parse(end);
    for (var i = 0; i < n; i++) {
      out.add(streakDayStr(d));
      d = d.subtract(const Duration(days: 1));
    }
    return out;
  }

  // The founder's record on the morning of Nov 26: a 33-day run
  // counted through Nov 24, Nov 25 evaluated but never counted.
  StreakState founderState() {
    final counted = runEnding('2026-11-24', 33);
    return StreakState(
      seeded: true,
      seededCurrent: 33,
      seededBest: 68,
      countedDays: counted,
      summaryCompletedDays: {...counted},
      lastEvaluatedDay: '2026-11-25',
      accrualMonth: '2026-11',
    );
  }

  late Map<String, String> disk;
  late Map<String, String> versions;
  late StreakStore store;
  late int pushCount;

  Future<bool> push(int c, int b, String j, {int? purchasedFreezes}) async {
    pushCount++;
    return true;
  }

  void primeStore(StreakState state) {
    disk[StreakStore.storageKey] = jsonEncode({
      'ownerEmail': null,
      'state': state.toJson(),
    });
  }

  SummaryResettlement resettler() {
    final r = SummaryResettlement(store: store);
    r.debugSetVersionStore(
      read: (key) async => versions[key],
      write: (key, value) async {
        versions[key] = value;
      },
    );
    return r;
  }

  final now = DateTime(2026, 11, 26, 10);

  setUp(() {
    disk = {};
    versions = {};
    pushCount = 0;
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

  test('the founder\'s Nov 25 heals: counted + summary-completed, '
      'streak +1 exactly, freeze lists untouched, gem hook fired '
      'once, NO celebration emitted', () async {
    final base = founderState();
    primeStore(base);
    await store.ensureLoaded();
    expect(runEndingAt(store.state!, '2026-11-24'), 33);

    // A watcher on the same store must observe NOTHING: the heal
    // never routes through the celebration path.
    final watcherEvents = <StreakCompletionResult>[];
    final streamEvents = <StreakCompletionResult>[];
    final watcherMarkers = <String, String>{};
    final watcher = SummaryCompletionWatcher(
      store: store,
      onCompletion: (r, s) => watcherEvents.add(r),
    );
    watcher.debugSetMarkerStore(
      read: (key) async => watcherMarkers[key],
      write: (key, value) async {
        watcherMarkers[key] = value;
      },
    );
    final sub = watcher.completions.listen(streamEvents.add);

    final gemDays = <String>[];
    final outcome = await resettler().maybeResettle(
      recordState: base,
      now: now,
      resolveContext: (dayStart) async =>
          contextFor(dayStart, entries: founderEntries()),
      pullSucceeded: true,
      seedCurrent: 33,
      seedBest: 68,
      seedStateJson: jsonEncode(base.toJson()),
      push: push,
      onResettled: (healed) async {
        gemDays.add(healed.day);
      },
    );

    expect(outcome.markerAdvanced, isTrue);
    expect(outcome.deferred, isFalse);
    expect(outcome.guardBlockedDay, isNull);
    expect(outcome.resettled, hasLength(1));
    expect(outcome.resettled.single.day, '2026-11-25');
    expect(outcome.resettled.single.result.newCount, 34);

    final healed = store.state!;
    expect(healed.countedDays, contains('2026-11-25'));
    expect(healed.countedDays, hasLength(34));
    expect(healed.summaryCompletedDays, contains('2026-11-25'));
    // Exactly +1: the run ending at the healed day is 34, one
    // more than the 33-run that ended Nov 24.
    expect(runEndingAt(healed, '2026-11-25'), 34);
    // Freeze/month lists byte-identical (all empty, as before).
    expect(healed.consumedSaveMonths, base.consumedSaveMonths);
    expect(healed.spoiledMonths, base.spoiledMonths);
    expect(healed.restoredDays, base.restoredDays);
    // The gem claim hook ran exactly once, for the healed day.
    expect(gemDays, ['2026-11-25']);
    // NO celebration: no watcher event, no stream event, and the
    // watcher's fired-day marker was never written.
    expect(watcherEvents, isEmpty);
    expect(streamEvents, isEmpty);
    expect(watcherMarkers, isEmpty);
    // The version marker advanced.
    expect(
      versions[SummaryResettlement.predicateVersionStorageKey],
      '${SummaryResettlement.currentPredicateVersion}',
    );

    await sub.cancel();
    watcher.dispose();
  });

  test('idempotent: a second run changes nothing', () async {
    final base = founderState();
    primeStore(base);
    final gemDays = <String>[];
    Future<SummaryResettlementOutcome> run() =>
        resettler().maybeResettle(
          recordState: store.state ?? base,
          now: now,
          resolveContext: (dayStart) async =>
              contextFor(dayStart, entries: founderEntries()),
          pullSucceeded: true,
          seedCurrent: 33,
          seedBest: 68,
          seedStateJson: jsonEncode(base.toJson()),
          push: push,
          onResettled: (healed) async {
            gemDays.add(healed.day);
          },
        );

    final first = await run();
    expect(first.resettled, hasLength(1));
    final afterFirst = store.state!;
    final pushesAfterFirst = pushCount;

    final second = await run();
    expect(second.resettled, isEmpty);
    // The healed day is counted now, so the second run finds no
    // candidate gap at all and returns from the cheap gate —
    // nothing re-completes, re-pushes, or re-claims.
    expect(store.state, afterFirst);
    expect(store.state!.countedDays, hasLength(34));
    expect(pushCount, pushesAfterFirst);
    expect(gemDays, ['2026-11-25']); // the hook did not re-fire
  });

  test('a skip-completed day WITHOUT its check-in stays uncounted '
      '(definitive scan; marker still advances)', () async {
    final base = founderState();
    primeStore(base);
    final outcome = await resettler().maybeResettle(
      recordState: base,
      now: now,
      resolveContext: (dayStart) async =>
          contextFor(dayStart, entries: founderEntries(withCheckIn: false)),
      pullSucceeded: true,
      seedCurrent: 33,
      seedBest: 68,
      seedStateJson: jsonEncode(base.toJson()),
      push: push,
    );
    expect(outcome.resettled, isEmpty);
    expect(outcome.markerAdvanced, isTrue);
    expect(store.state!.countedDays, isNot(contains('2026-11-25')));
    expect(
      store.state!.summaryCompletedDays,
      isNot(contains('2026-11-25')),
    );
    expect(store.state!.countedDays, hasLength(33));
    expect(runEndingAt(store.state!, '2026-11-24'), 33);
  });

  test('an UNATTESTED plan defers without burning the one shot: '
      'marker untouched, and a later attested run heals', () async {
    final base = founderState();
    primeStore(base);
    final deferred = await resettler().maybeResettle(
      recordState: base,
      now: now,
      resolveContext: (dayStart) async => contextFor(
        dayStart,
        entries: founderEntries(),
        attested: false,
      ),
      pullSucceeded: true,
      seedCurrent: 33,
      seedBest: 68,
      seedStateJson: jsonEncode(base.toJson()),
      push: push,
    );
    expect(deferred.resettled, isEmpty);
    expect(deferred.deferred, isTrue);
    expect(deferred.markerAdvanced, isFalse);
    expect(versions, isEmpty);
    expect(store.state!.countedDays, isNot(contains('2026-11-25')));

    final healed = await resettler().maybeResettle(
      recordState: store.state ?? base,
      now: now,
      resolveContext: (dayStart) async =>
          contextFor(dayStart, entries: founderEntries()),
      pullSucceeded: true,
      seedCurrent: 33,
      seedBest: 68,
      seedStateJson: jsonEncode(base.toJson()),
      push: push,
    );
    expect(healed.resettled, hasLength(1));
    expect(healed.markerAdvanced, isTrue);
    expect(store.state!.countedDays, contains('2026-11-25'));
  });
}
