import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';

/// Phase 1, item 5 — engine tests (spec §8 numbering).

String day(int offset) => addDaysToDayKey('2026-09-01', offset);

int tsFor(String dayKey, {int hour = 12, int minute = 0}) {
  final p = parseDayKey(dayKey)!;
  return DateTime(p.year, p.month, p.day, hour, minute)
      .millisecondsSinceEpoch;
}

DailyBiometrics bio(
  String date, {
  int? sleep,
  int? score,
  int? scoreSleep,
  int? scoreHrv,
  int? scoreRestingHr,
}) =>
    DailyBiometrics(
      date: date,
      sleepMinutes: sleep,
      dailyScore: score,
      scoreSleep: scoreSleep,
      scoreHrv: scoreHrv,
      scoreRestingHr: scoreRestingHr,
    );

Map<String, DailyBiometrics> bioMap(List<DailyBiometrics> rows) =>
    {for (final r in rows) r.date: r};

const categories = [
  QuickLogCategory(
      id: 1,
      name: 'Symptoms',
      icon: 'circle',
      colorHex: '#CCCCCC',
      isDefault: true,
      sortOrder: 0),
  QuickLogCategory(
      id: 6,
      name: 'Mood & Energy',
      icon: 'circle',
      colorHex: '#CCCCCC',
      isDefault: true,
      sortOrder: 1),
];

QuickLogEntry entry({
  required int id,
  required int categoryId,
  required String body,
  required String chips,
  String manualText = '',
  required int timestamp,
}) =>
    QuickLogEntry(
      id: id,
      categoryId: categoryId,
      body: body,
      chips: chips,
      manualText: manualText,
      timestamp: timestamp,
    );

QuickLogEntry feeling(int id, String dayKey, int level) => entry(
      id: id,
      categoryId: 6,
      body: 'Feeling: $level/5 Today',
      chips: '["Daily Ranking"]',
      timestamp: tsFor(dayKey),
    );

CorrelationInputs inputs({
  Map<String, DailyBiometrics> biometrics = const {},
  List<QuickLogEntry> entries = const [],
  List<IntakeTargetHistoryEntry> targetHistory = const [],
  List<MedChangeEventInput> medEvents = const [],
  String nowDayKey = '2026-09-28',
}) =>
    CorrelationInputs(
      biometrics: biometrics,
      entries: entries,
      categories: categories,
      targetHistory: targetHistory,
      medEvents: medEvents,
      nowDayKey: nowDayKey,
    );

InsightRecord find(List<InsightRecord> records, String splitId) =>
    records.firstWhere((r) => r.splitId == splitId);

void main() {
  group('derivation correctness', () {
    test('1. hand-computed group stats; zero-rule exclusion', () {
      final rows = <DailyBiometrics>[];
      // Short nights (offsets 0-4, sleep 300): next-day scores
      // 50,60,70,80,90 -> mean 70, median 70.
      // Long nights (offsets 5-13, sleep 500): next-day scores 80.
      for (var i = 0; i <= 14; i++) {
        rows.add(bio(
          day(i),
          sleep: i <= 13 ? (i <= 4 ? 300 : 500) : null,
          score: i == 0 ? null : (i <= 5 ? 40 + i * 10 : 80),
          scoreSleep: i == 0 ? null : (i <= 5 ? 40 + i * 10 : 80),
        ));
      }
      // Zero-rule traps: a stored sleep 0 night with a terrible
      // next-day score, and a short night with NO next-day score.
      rows.add(bio(day(15), sleep: 0));
      rows.add(bio(day(16), sleep: 300, score: 10));
      rows.add(restingHrOnly());
      final records = computeCorrelationInsights(
        inputs(biometrics: bioMap(rows)),
        computedAtMs: 1,
      );
      final f1a = find(records, 'F1a');
      expect(f1a.state, InsightState.numbers);
      expect(f1a.groups[0].n, 5);
      expect(f1a.groups[0].mean, 70);
      expect(f1a.groups[0].median, 70);
      expect(f1a.groups[1].n, 9);
      expect(f1a.groups[1].mean, 80);
      expect(f1a.groups[1].median, 80);
      // Component outcome mirrors the primary groups with its own
      // floor evaluation.
      final sleepComponent = f1a.componentOutcomes
          .firstWhere((c) => c.outcomeId == 'scoreSleep');
      expect(sleepComponent.state, InsightState.numbers);
      expect(sleepComponent.groups[0].mean, 70);
    });

    test('2. lag alignment (F1 pairs night D with day D+1)', () {
      final rows = <DailyBiometrics>[];
      for (var i = 0; i <= 14; i++) {
        rows.add(bio(
          day(i),
          sleep: i <= 13 ? (i <= 4 ? 300 : 500) : null,
          // Scores exist ONLY on outcome days 1..14: a same-day
          // pairing would find n=4 for group A, the lag finds 5.
          score: i == 0 ? null : (i <= 5 ? 60 : 70),
        ));
      }
      final records =
          computeCorrelationInsights(inputs(biometrics: bioMap(rows)));
      final f1a = find(records, 'F1a');
      expect(f1a.groups[0].n, 5);
      expect(f1a.groups[0].mean, 60);
      expect(f1a.groups[1].n, 9);
      expect(f1a.groups[1].mean, 70);
    });

    test('2b. 04:00 boundary on the entry side', () {
      expect(energyDayLabel(tsFor('2026-09-10', hour: 3, minute: 59)),
          '2026-09-09');
      expect(energyDayLabel(tsFor('2026-09-10', hour: 4, minute: 0)),
          '2026-09-10');
      final byDay = deriveFeelingByDay([
        feeling(1, '2026-09-10', 2)
            .copyWithTimestamp(tsFor('2026-09-10', hour: 3, minute: 59)),
        feeling(2, '2026-09-10', 4)
            .copyWithTimestamp(tsFor('2026-09-10', hour: 4, minute: 0)),
      ], categories);
      expect(byDay, {'2026-09-09': 2, '2026-09-10': 4});
    });

    test('3. trailing-90-day window; through-date equals days averaged',
        () {
      final entries = <QuickLogEntry>[];
      final rows = <DailyBiometrics>[];
      var id = 0;
      // Old high days (before the window start 2026-07-01).
      for (final d in [
        '2026-06-20',
        '2026-06-21',
        '2026-06-22',
        '2026-06-23',
        '2026-06-24',
      ]) {
        entries.add(feeling(id++, d, 5));
        rows.add(bio(d, score: 100));
      }
      // In-window low days: 9, scores 40.
      for (var i = 0; i < 9; i++) {
        final d = addDaysToDayKey('2026-09-10', i);
        entries.add(feeling(id++, d, 1));
        rows.add(bio(d, score: 40));
      }
      // In-window high days: only 4, scores 50.
      for (var i = 0; i < 4; i++) {
        final d = addDaysToDayKey('2026-09-20', i);
        entries.add(feeling(id++, d, 5));
        rows.add(bio(d, score: 50));
      }
      rows.add(bio('2026-09-28', score: 55)); // the latest input day
      final records = computeCorrelationInsights(
          inputs(biometrics: bioMap(rows), entries: entries));
      final f4 = find(records, 'F4');
      expect(f4.throughDate, '2026-09-28');
      expect(f4.windowKey, 'last90d');
      expect(f4.groups[0].n, 9); // low, in window
      expect(f4.groups[1].n, 4); // high, in window only (old 5 excluded)
      expect(f4.state, InsightState.progress);
    });

    test('4. F5 passthrough: record equals computeMedChangeWindows', () {
      final rows = <DailyBiometrics>[];
      for (var i = 0; i < 28; i++) {
        rows.add(bio(addDaysToDayKey('2026-09-01', i),
            score: i < 14 ? 60 : 80));
      }
      final event = MedChangeEventInput(
        id: 'ev1',
        medId: 'm1',
        medName: 'MedA',
        type: 'start',
        newSnapshot: const MedFieldSnapshot(
            dose: '5 mg',
            frequency: 'Daily',
            startDate: '2026-09-15',
            endDate: 'Present',
            isPresent: true),
        effectiveDate: '2026-09-15',
        recordedAt: tsFor('2026-09-15', hour: 9),
        source: 'tools',
      );
      final windows = computeMedChangeWindows(
        event: event,
        allEvents: [event],
        biometrics: bioMap(rows),
      );
      expect(windows.before.n, 14);
      expect(windows.before.mean, 60);
      expect(windows.after.n, 14);
      expect(windows.after.mean, 80);

      final records = computeCorrelationInsights(
          inputs(biometrics: bioMap(rows), medEvents: [event]));
      final f5 = find(records, 'ev1');
      expect(f5.familyId, 'F5');
      expect(f5.windowKey, 'event:ev1');
      expect(f5.state, InsightState.numbers);
      expect(f5.groups[0].n, windows.before.n);
      expect(f5.groups[0].mean, windows.before.mean);
      expect(f5.groups[1].n, windows.after.n);
      expect(f5.groups[1].mean, windows.after.mean);
      expect(f5.headerLabel, 'Started MedA · 5 mg');
      expect(f5.subjectName, 'MedA');
    });
  });

  group('minimums and honest states', () {
    List<InsightRecord> f4Records(int lowCount, int highCount) {
      final entries = <QuickLogEntry>[];
      final rows = <DailyBiometrics>[];
      var id = 0;
      for (var i = 0; i < lowCount; i++) {
        entries.add(feeling(id++, day(i), 2));
        rows.add(bio(day(i), score: 40));
      }
      for (var i = 0; i < highCount; i++) {
        entries.add(feeling(id++, day(lowCount + i), 5));
        rows.add(bio(day(lowCount + i), score: 80));
      }
      return computeCorrelationInsights(
          inputs(biometrics: bioMap(rows), entries: entries));
    }

    test('5. floors at n=4 vs n=5 and the 14 total', () {
      final below = find(f4Records(4, 10), 'F4');
      expect(below.state, InsightState.progress);
      expect(below.groups[0].n, 4);
      expect(below.groups[0].mean, isNull);
      expect(below.groups[0].median, isNull);
      expect(below.groups[1].mean, isNull);

      final totalTooSmall = find(f4Records(5, 5), 'F4');
      expect(totalTooSmall.state, InsightState.progress);

      final atFloor = find(f4Records(5, 9), 'F4');
      expect(atFloor.state, InsightState.numbers);
      expect(atFloor.groups[0].mean, 40);
      expect(atFloor.groups[1].mean, 80);
    });

    test('6. unavailable + global-empty produce S7/progress only', () {
      final records = computeCorrelationInsights(inputs());
      expect(records.where((r) => r.state == InsightState.numbers), isEmpty);
      final f2 = records.where((r) => r.familyId == 'F2').toList();
      expect(f2.length, 6);
      expect(
          f2.every((r) => r.state == InsightState.unavailable), isTrue);
      final f5 = records.where((r) => r.familyId == 'F5').toList();
      expect(f5.length, 1);
      expect(f5.single.state, InsightState.unavailable);
      for (final split in ['F1a', 'F1b', 'F3', 'F4']) {
        final r = find(records, split);
        expect(r.state, InsightState.progress, reason: split);
        expect(r.groups.every((g) => g.mean == null), isTrue);
      }
    });

    test('7. F4 middle value and no-check-in days are excluded', () {
      final entries = <QuickLogEntry>[];
      final rows = <DailyBiometrics>[];
      var id = 0;
      for (var i = 0; i < 5; i++) {
        entries.add(feeling(id++, day(i), 2));
        rows.add(bio(day(i), score: 40));
      }
      for (var i = 0; i < 5; i++) {
        entries.add(feeling(id++, day(5 + i), 3)); // middle: neither group
        rows.add(bio(day(5 + i), score: 100));
      }
      for (var i = 0; i < 9; i++) {
        entries.add(feeling(id++, day(10 + i), 4));
        rows.add(bio(day(10 + i), score: 80));
      }
      rows.add(bio(day(19), score: 1)); // no check-in: absent
      final f4 = find(
          computeCorrelationInsights(
              inputs(biometrics: bioMap(rows), entries: entries)),
          'F4');
      expect(f4.state, InsightState.numbers);
      expect(f4.groups[0].n, 5);
      expect(f4.groups[0].mean, 40);
      expect(f4.groups[1].n, 9);
      expect(f4.groups[1].mean, 80);
    });

    test('8. F1b per-night need: need changes across the window; '
        'null-need nights in neither group', () {
      final sleep = <String, int>{};
      // Ten 480-minute nights establish an early need of ~480.
      for (var i = 0; i < 10; i++) {
        sleep[addDaysToDayKey('2026-08-01', i)] = 480;
      }
      // A 500-minute night is at/above the early need.
      sleep['2026-08-11'] = 500;
      expect(sleepNightBelowNeed(sleep, '2026-08-11'), isFalse);
      // Twenty-nine 600-minute nights move the need to ~600.
      for (var i = 0; i < 29; i++) {
        sleep[addDaysToDayKey('2026-08-12', i)] = 600;
      }
      // The same 500 minutes are now below the night's own need.
      sleep['2026-09-10'] = 500;
      expect(sleepNightBelowNeed(sleep, '2026-09-10'), isTrue);
      // Too few prior nights: no estimate, neither group.
      expect(sleepNightBelowNeed(sleep, '2026-08-03'), isNull);
      expect(sleepNightBelowNeed(sleep, '2026-12-25'), isNull);

      // Record level: only null-need nights -> both counts 0.
      final rows = <DailyBiometrics>[
        bio('2026-09-01', sleep: 480),
        bio('2026-09-02', sleep: 480, score: 50),
        bio('2026-09-03', sleep: 480, score: 50),
        bio('2026-09-04', score: 50),
      ];
      final f1b = find(
          computeCorrelationInsights(inputs(biometrics: bioMap(rows))),
          'F1b');
      expect(f1b.state, InsightState.progress);
      expect(f1b.groups[0].n, 0);
      expect(f1b.groups[1].n, 0);
    });
  });

  group('adversarial honesty', () {
    test('A1. entangled sleep/flare: F3 carries the COMPUTED '
        'co-occurrence; no attribution wording anywhere', () {
      final entries = <QuickLogEntry>[];
      final rows = <DailyBiometrics>[];
      var id = 0;
      // 7 flare days (sleep 300, score 40), 7 non-flare days
      // (sleep 500, score 80) — sleep and flare fully entangled.
      for (var i = 0; i < 14; i++) {
        final flare = i.isEven;
        rows.add(bio(day(i),
            sleep: flare ? 300 : 500, score: flare ? 40 : 80));
        if (flare) {
          entries.add(entry(
            id: id++,
            categoryId: 1,
            body: 'Flare day · Bad',
            chips: '["Flare Day", "Bad"]',
            timestamp: tsFor(day(i)),
          ));
        }
      }
      final records = computeCorrelationInsights(
          inputs(biometrics: bioMap(rows), entries: entries));
      final f3 = find(records, 'F3');
      expect(f3.state, InsightState.numbers);
      expect(f3.coOccurrence, isNotNull);
      expect(f3.coOccurrence!.confounderLabel, 'sleep');
      expect(f3.coOccurrence!.groupADays, 'flare');
      expect(f3.coOccurrence!.groupBDays, 'non-flare');
      expect(f3.coOccurrence!.valueA, 300);
      expect(f3.coOccurrence!.valueB, 500);

      final rendered = [
        correlationComparisonSentence(
          groupALabel: f3.groups[0].label,
          groupAN: f3.groups[0].n,
          groupAMean: f3.groups[0].mean!,
          groupBLabel: f3.groups[1].label,
          groupBN: f3.groups[1].n,
          groupBMean: f3.groups[1].mean!,
        ),
        correlationCoOccurrenceSentence(
          groupADays: f3.coOccurrence!.groupADays,
          confounderLabel: f3.coOccurrence!.confounderLabel,
          valueA: f3.coOccurrence!.valueA,
          groupBDays: f3.coOccurrence!.groupBDays,
          valueB: f3.coOccurrence!.valueB,
        ),
        correlationCaption,
        jsonEncode(f3.toJson()),
      ].join('\n').toLowerCase();
      for (final banned in correlationCopyBlocklist) {
        expect(rendered.contains(banned.toLowerCase()), isFalse,
            reason: banned);
      }
      expect(rendered.contains('%'), isFalse);
    });

    test('A2. tiny-n med trap: 2 terrible days after a start render '
        'progress with no averages', () {
      final rows = <DailyBiometrics>[];
      for (var i = 0; i < 14; i++) {
        rows.add(bio(addDaysToDayKey('2026-09-06', i), score: 70));
      }
      rows.add(bio('2026-09-20', score: 10));
      rows.add(bio('2026-09-21', score: 20));
      final event = MedChangeEventInput(
        id: 'ev-tiny',
        medId: 'm1',
        medName: 'MedA',
        type: 'start',
        newSnapshot: const MedFieldSnapshot(
            dose: '5 mg',
            frequency: 'Daily',
            startDate: '2026-09-20',
            endDate: 'Present',
            isPresent: true),
        effectiveDate: '2026-09-20',
        recordedAt: tsFor('2026-09-20', hour: 9),
        source: 'tools',
      );
      final f5 = find(
          computeCorrelationInsights(
              inputs(biometrics: bioMap(rows), medEvents: [event])),
          'ev-tiny');
      expect(f5.state, InsightState.progress);
      expect(f5.groups[0].n, 14);
      expect(f5.groups[1].n, 2);
      expect(f5.groups.every((g) => g.mean == null), isTrue);
    });

    test('A3. no-data-day trap: missed group counts ONLY '
        'logged-missed days', () {
      final entries = <QuickLogEntry>[];
      final rows = <DailyBiometrics>[];
      var id = 0;
      QuickLogEntry intake(String d, int fluidMl) => entry(
            id: id++,
            categoryId: 1,
            body: 'Water',
            chips: '["Intake", "Water"]',
            manualText: '{"v":1,"kind":"Water","fluidMl":$fluidMl}',
            timestamp: tsFor(d),
          );
      // Days 0-6 hit (fluid 1200 >= 1000), outcome score 80.
      // Days 7-13 logged-missed (500), outcome 60.
      // Days 14-18 unlogged, outcome 10 (the worst scores — the
      // trap: counting them as misses would poison group B).
      for (var i = 0; i < 19; i++) {
        if (i < 7) entries.add(intake(day(i), 1200));
        if (i >= 7 && i < 14) entries.add(intake(day(i), 500));
        rows.add(bio(day(i + 1), score: i < 7 ? 80 : (i < 14 ? 60 : 10)));
      }
      final records = computeCorrelationInsights(inputs(
        biometrics: bioMap(rows),
        entries: entries,
        targetHistory: const [
          IntakeTargetHistoryEntry(
              fluidTargetMl: 1000,
              sodiumTargetMg: 6000,
              effectiveFromDay: '2026-08-01'),
        ],
      ));
      final fluid = find(records, 'fluid-score');
      expect(fluid.state, InsightState.numbers);
      expect(fluid.groups[0].n, 7);
      expect(fluid.groups[0].mean, 80);
      expect(fluid.groups[1].n, 7); // logged-missed only
      expect(fluid.groups[1].mean, 60);
    });

    test('A4. registry audit: no grouping variable is a score '
        'component or a transform of the outcome', () {
      const scoreComponents = {
        'dailyScore',
        'scoreSleep',
        'scoreHrv',
        'scoreRestingHr',
      };
      expect(correlationFamilyRegistry, isNotEmpty);
      for (final def in correlationFamilyRegistry) {
        expect(scoreComponents.contains(def.groupingVariable), isFalse,
            reason: '${def.splitId} groups by ${def.groupingVariable}');
        expect(def.groupingVariable == def.outcomeVariable, isFalse,
            reason: def.splitId);
        expect(def.groupingVariable.contains('score'), isFalse,
            reason: def.splitId);
      }
      expect(
        correlationFamilyRegistry.map((d) => d.familyId).toSet(),
        {'F1', 'F2', 'F3', 'F4', 'F5'},
      );
      expect(
        correlationFamilyRegistry.map((d) => d.splitId).toList(),
        [
          'F1a',
          'F1b',
          'fluid-score',
          'sodium-score',
          'fluid-flare',
          'sodium-flare',
          'fluid-migraine',
          'sodium-migraine',
          'F3',
          'F4',
          'F5',
        ],
      );
    });

    test('A5. registry golden: thresholds/lags/windows equal the '
        'spec constants exactly', () {
      expect(correlationMinPerGroup, 5);
      expect(correlationMinTotal, 14);
      expect(correlationWindowDays, 90);
      expect(correlationF5WindowDays, 14);
      CorrelationFamilyDefinition def(String split) =>
          correlationFamilyRegistry
              .firstWhere((d) => d.splitId == split);
      expect(def('F1a').threshold, 360);
      expect(def('F1a').lagDays, 1);
      expect(def('F1a').windowDays, 90);
      expect(def('F1b').lagDays, 1);
      expect(def('F1b').windowDays, 90);
      for (final s in [
        'fluid-score',
        'sodium-score',
        'fluid-flare',
        'sodium-flare',
        'fluid-migraine',
        'sodium-migraine',
      ]) {
        expect(def(s).lagDays, 1, reason: s);
        expect(def(s).windowDays, 90, reason: s);
      }
      expect(def('F3').lagDays, 0);
      expect(def('F4').lagDays, 0);
      expect(def('F5').windowDays, 14);
    });

    test('A7 (engine half). mutating an input changes the '
        'fingerprint; the stale record keeps its throughDate', () {
      final entries = <QuickLogEntry>[
        feeling(1, '2026-09-10', 2),
        feeling(2, '2026-09-11', 5),
      ];
      final rows = bioMap([
        bio('2026-09-10', score: 40),
        bio('2026-09-11', score: 80),
      ]);
      final before = inputs(biometrics: rows, entries: entries);
      final fpBefore = computeCorrelationFingerprints(before);
      final recordBefore =
          find(computeCorrelationInsights(before), 'F4');
      expect(recordBefore.throughDate, '2026-09-11');
      expect(recordBefore.inputFingerprint, fpBefore['F4/F4']);

      final mutated = inputs(
        biometrics: bioMap([
          ...rows.values,
          bio('2026-09-12', score: 90),
        ]),
        entries: [...entries, feeling(3, '2026-09-12', 5)],
      );
      final fpAfter = computeCorrelationFingerprints(mutated);
      expect(fpAfter['F4/F4'], isNot(fpBefore['F4/F4']));
      // The previously computed (now stale) record is immutable:
      // it still carries its original through-date and fingerprint.
      expect(recordBefore.throughDate, '2026-09-11');
      expect(recordBefore.inputFingerprint, fpBefore['F4/F4']);
    });
  });

  group('contract fixtures', () {
    test('intake entries per item 4 §4.1, incl. unparseable and '
        'salt-only days', () {
      final entries = <QuickLogEntry>[
        entry(
          id: 1,
          categoryId: 1,
          body: 'Water · 16 fl oz',
          chips: '["Intake","Water"]',
          manualText: '{"v":1,"kind":"Water","fluidMl":473}',
          timestamp: tsFor('2026-09-05'),
        ),
        entry(
          id: 2,
          categoryId: 1,
          body: 'Salt · 1 g',
          chips: '["Intake","Salt"]',
          manualText: '{"v":1,"kind":"Salt","sodiumMg":1000}',
          timestamp: tsFor('2026-09-06'),
        ),
        entry(
          id: 3,
          categoryId: 1,
          body: 'Water',
          chips: '["Intake","Water"]',
          manualText: 'not a payload',
          timestamp: tsFor('2026-09-10'),
        ),
        // Legacy ', '-joined chips shape still parses.
        entry(
          id: 4,
          categoryId: 1,
          body: 'Water',
          chips: 'Intake, Water',
          manualText: '{"v":1,"kind":"Water","fluidMl":200}',
          timestamp: tsFor('2026-09-05', hour: 18),
        ),
      ];
      final derived = deriveIntake(entries);
      expect(derived.unparseableCount, 1); // excluded AND counted
      expect(derived.byDay.containsKey('2026-09-10'), isFalse);
      expect(derived.byDay['2026-09-05']!.fluidMl, 473 + 200);
      expect(derived.byDay['2026-09-05']!.eventCount, 2);
      // Salt-only day: fluid total 0 (fluid-missed, not no-data),
      // sodium per payload.
      expect(derived.byDay['2026-09-06']!.fluidMl, 0);
      expect(derived.byDay['2026-09-06']!.sodiumMg, 1000);
      expect(derived.byDay['2026-09-06']!.eventCount, 1);

      // Classification through the engine: targets fluid 400 /
      // sodium 6000 in force from 2026-01-01.
      final rows = bioMap([
        bio('2026-09-06', score: 70), // outcome of the 09-05 hit day
        bio('2026-09-07', score: 50), // outcome of the salt-only day
      ]);
      final records = computeCorrelationInsights(inputs(
        biometrics: rows,
        entries: entries,
        targetHistory: const [
          IntakeTargetHistoryEntry(
              fluidTargetMl: 400,
              sodiumTargetMg: 6000,
              effectiveFromDay: '2026-01-01'),
        ],
      ));
      final fluid = find(records, 'fluid-score');
      expect(fluid.groups[0].n, 1); // 673 >= 400: hit
      expect(fluid.groups[1].n, 1); // salt-only day: fluid 0 < 400
      final sodium = find(records, 'sodium-score');
      expect(sodium.groups[0].n, 0);
      expect(sodium.groups[1].n, 2); // both logged days below 6000
    });

    test('med-event fixtures in the exact 2a toJson shape', () {
      final monthPrecision = MedChangeEventInput.fromJson({
        'id': 'ev-m',
        'medId': 'm1',
        'medName': 'MedB',
        'type': 'start',
        'old': null,
        'new': {
          'dose': '5 mg',
          'frequency': 'Daily',
          'startDate': '2026-09',
          'endDate': 'Present',
          'isPresent': true,
        },
        'effectiveDate': '2026-09', // month precision: not a day
        'recordedAt': tsFor('2026-09-15', hour: 10),
        'source': 'tools',
      });
      // Falls back to the recordedAt device-local day.
      expect(medChangeAnchorDay(monthPrecision), '2026-09-15');
      expect(monthPrecision.newSnapshot?.dose, '5 mg');

      final doseChange = MedChangeEventInput.fromJson({
        'id': 'ev-d',
        'medId': 'm1',
        'medName': 'MedB',
        'type': 'dose_change',
        'old': {
          'dose': '5 mg',
          'frequency': 'Daily',
          'startDate': '2026-09-01',
          'endDate': 'Present',
          'isPresent': true,
        },
        'new': {
          'dose': '10 mg',
          'frequency': 'Daily',
          'startDate': '2026-09-01',
          'endDate': 'Present',
          'isPresent': true,
        },
        'effectiveDate': null,
        'recordedAt': tsFor('2026-09-20', hour: 9),
        'source': 'settings',
      });
      expect(medChangeAnchorDay(doseChange), '2026-09-20');
      expect(medChangeHeaderLabel(doseChange),
          'MedB dose changed from 5 mg to 10 mg');
      // Change day counts in the AFTER window for a dose change:
      // a score only on the anchor day lands in after, not before.
      final windows = computeMedChangeWindows(
        event: doseChange,
        allEvents: [doseChange],
        biometrics: bioMap([bio('2026-09-20', score: 66)]),
      );
      expect(windows.after.n, 1);
      expect(windows.before.n, 0);
    });

    test('F5 truncation at a neighboring same-med change', () {
      final rows = <DailyBiometrics>[];
      for (var i = 0; i < 30; i++) {
        rows.add(bio(addDaysToDayKey('2026-09-01', i), score: 50));
      }
      MedChangeEventInput ev(String id, String type, String day) =>
          MedChangeEventInput(
            id: id,
            medId: 'm1',
            medName: 'MedA',
            type: type,
            effectiveDate: day,
            recordedAt: tsFor(day, hour: 9),
            source: 'tools',
          );
      final start = ev('ev-s', 'start', '2026-09-10');
      final dose = ev('ev-dc', 'dose_change', '2026-09-15');
      final windows = computeMedChangeWindows(
        event: start,
        allEvents: [start, dose],
        biometrics: bioMap(rows),
      );
      expect(windows.after.truncated, isTrue);
      expect(windows.after.n, 5); // 09-10 .. 09-14 only
      expect(windows.before.truncated, isFalse);
    });

    test('F2 incidence: flare counts with denominators, floors on '
        'denominators', () {
      final entries = <QuickLogEntry>[];
      var id = 0;
      // 7 hit days and 7 missed days; a flare on the day after
      // every hit day, none after missed days.
      for (var i = 0; i < 14; i++) {
        final hit = i.isEven;
        entries.add(entry(
          id: id++,
          categoryId: 1,
          body: 'Water',
          chips: '["Intake", "Water"]',
          manualText:
              '{"v":1,"kind":"Water","fluidMl":${hit ? 1200 : 500}}',
          timestamp: tsFor(day(i)),
        ));
        if (hit) {
          entries.add(entry(
            id: id++,
            categoryId: 1,
            body: 'Flare day · Bad',
            chips: '["Flare Day", "Bad"]',
            timestamp: tsFor(day(i + 1)),
          ));
        }
      }
      final records = computeCorrelationInsights(inputs(
        entries: entries,
        // A day-14 row makes day 14 the latest input day, so the
        // last intake day's next day is assessable.
        biometrics: {
          day(14): DailyBiometrics(date: day(14), restingHrBpm: 60),
        },
        targetHistory: const [
          IntakeTargetHistoryEntry(
              fluidTargetMl: 1000, effectiveFromDay: '2026-08-01'),
        ],
      ));
      final flare = find(records, 'fluid-flare');
      expect(flare.state, InsightState.numbers);
      expect(flare.incidence, const IncidenceResult(x: 7, n: 7, y: 0, m: 7));
      expect(
        correlationFlareIncidenceSentence(x: 7, n: 7, y: 0, m: 7),
        'A flare was logged on 7 of the 7 days after days your logged intake reached your target, and on 0 of the 7 days after days your logged intake was below your target.',
      );
    });
  });

  group('copy lint (A6, engine half)', () {
    test('no static engine string matches the blocklist or '
        'contains a banned character', () {
      for (final s in correlationStaticStrings) {
        for (final banned in correlationCopyBlocklist) {
          expect(s.toLowerCase().contains(banned.toLowerCase()), isFalse,
              reason: '$s vs $banned');
        }
        expect(s.contains(correlationBannedCharacter), isFalse, reason: s);
      }
      // Juno's final strings, byte-verbatim spot checks.
      expect(correlationTitle, 'Patterns in your records');
      expect(correlationCaption,
          'A pattern in your records, not a cause. Other things differed between these days too.');
      expect(correlationUnavailableF2,
          'This pattern needs salt and fluid logging, which is not in Tabs yet.');
      expect(correlationUnavailableF5,
          'This pattern needs your medication change history. There are no recorded medication changes in Tabs yet.');
      expect(correlationSurfaceDisclaimer,
          'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition.');
      expect(
        correlationProgressSentence(
            groupALabel: 'a', groupAN: 1, groupBLabel: 'b', groupBN: 2),
        'Not enough days yet. This pattern needs at least 5 days in each group, and 14 days in total. So far: 1 a, 2 b — 3 days in total.',
      );
    });
  });
}

/// A row carrying only a resting-HR value (no score, no sleep).
DailyBiometrics restingHrOnly() => DailyBiometrics(
      date: day(17),
      restingHrBpm: 60,
    );

extension on QuickLogEntry {
  QuickLogEntry copyWithTimestamp(int ts) => QuickLogEntry(
        id: id,
        categoryId: categoryId,
        body: body,
        chips: chips,
        manualText: manualText,
        timestamp: ts,
      );
}
