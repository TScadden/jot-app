import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';
import 'package:tabs_lab/src/features/home/daily_score_vocabulary.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// In-memory fake for the store's storage functions.
class _FakeStore {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// [count] consecutive dates ending the day BEFORE [anchor]
/// (oldest first), for building baseline history.
List<String> _priorDates(String anchor, int count) {
  final a = DateTime.parse(anchor);
  return [
    for (var i = count; i >= 1; i--) _ds(a.subtract(Duration(days: i))),
  ];
}

Map<String, DailyBiometrics> _mapOf(Iterable<DailyBiometrics> rows) =>
    {for (final r in rows) r.date: r};

HealthHistoryStore _fakeStore(_FakeStore fake) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return store;
}

void main() {
  group('formula: sleep component', () {
    test('linear below need, capped at need, no bonus above', () {
      expect(scoreSleepComponent(0), 0);
      expect(scoreSleepComponent(0.5), 50);
      expect(scoreSleepComponent(0.75), 75);
      expect(scoreSleepComponent(1.0), 100);
      expect(scoreSleepComponent(1.4), 100);
    });
  });

  group('formula: HRV component anchors', () {
    // Baseline median 40 ms.
    test('at baseline = 70', () => expect(scoreHrvComponent(40, 40), 70));
    test('+25% saturates at 100', () {
      expect(scoreHrvComponent(50, 40), 100);
      expect(scoreHrvComponent(80, 40), 100);
    });
    test('-40% saturates at 0', () {
      expect(scoreHrvComponent(24, 40), 0);
      expect(scoreHrvComponent(10, 40), 0);
    });
    test('interpolates linearly between anchors', () {
      expect(scoreHrvComponent(32, 40), closeTo(35, 1e-9)); // -20%
      expect(scoreHrvComponent(45, 40), closeTo(85, 1e-9)); // +12.5%
    });
  });

  group('formula: resting HR component anchors (inverted)', () {
    // Baseline median 60 bpm.
    test('at baseline = 70', () => expect(scoreRestingHrComponent(60, 60), 70));
    test('benefit saturates at -10% and goes no higher', () {
      expect(scoreRestingHrComponent(54, 60), 100);
      expect(scoreRestingHrComponent(40, 60), 100); // far below: still 100
    });
    test('+20% saturates at 0', () {
      expect(scoreRestingHrComponent(72, 60), 0);
      expect(scoreRestingHrComponent(90, 60), 0);
    });
    test('interpolates linearly between anchors', () {
      expect(scoreRestingHrComponent(57, 60), closeTo(85, 1e-9)); // -5%
      expect(scoreRestingHrComponent(66, 60), closeTo(35, 1e-9)); // +10%
    });
  });

  test('medianOf handles odd and even counts', () {
    expect(medianOf([3, 1, 2]), 2);
    expect(medianOf([4, 1, 3, 2]), 2.5);
  });

  group('computeDailyScore', () {
    const target = '2026-10-17';

    test('sleep only: renormalized to the sleep score alone', () {
      final days = _mapOf([
        for (final d in _priorDates(target, 28))
          DailyBiometrics(date: d, sleepMinutes: 480),
        const DailyBiometrics(date: target, sleepMinutes: 240),
      ]);
      final c = computeDailyScore(days, target)!;
      // Need from priors = 480 (p75 480, no debt) → ratio 0.5.
      expect(c.sleepScore, 50);
      expect(c.hrvScore, isNull);
      expect(c.restingHrScore, isNull);
      expect(c.dailyScore, 50);
      expect(c.asleepMinutes, 240);
      expect(c.sleepNeedMinutes, 480);
    });

    test('HRV only: at baseline median scores 70', () {
      final days = _mapOf([
        for (final d in _priorDates(target, 10))
          DailyBiometrics(date: d, hrvRmssdMs: 40),
        const DailyBiometrics(date: target, hrvRmssdMs: 40),
      ]);
      final c = computeDailyScore(days, target)!;
      expect(c.hrvScore, 70);
      expect(c.dailyScore, 70);
      expect(c.hrvBaselineMs, 40);
    });

    test('resting HR only: -10% below baseline saturates at 100', () {
      final days = _mapOf([
        for (final d in _priorDates(target, 10))
          DailyBiometrics(date: d, restingHrBpm: 60),
        const DailyBiometrics(date: target, restingHrBpm: 54),
      ]);
      final c = computeDailyScore(days, target)!;
      expect(c.restingHrScore, 100);
      expect(c.dailyScore, 100);
    });

    test('two components renormalize over their combined weight', () {
      final days = _mapOf([
        for (final d in _priorDates(target, 28))
          DailyBiometrics(date: d, sleepMinutes: 480, hrvRmssdMs: 40),
        const DailyBiometrics(date: target, sleepMinutes: 240, hrvRmssdMs: 40),
      ]);
      final c = computeDailyScore(days, target)!;
      // (40*50 + 35*70) / 75 = 59.33…
      expect(c.dailyExact, closeTo(59.333, 0.001));
      expect(c.dailyScore, 59);
    });

    test('fewer than 7 baseline days: component unavailable', () {
      final days = _mapOf([
        for (final d in _priorDates(target, 6))
          DailyBiometrics(date: d, hrvRmssdMs: 40),
        const DailyBiometrics(date: target, hrvRmssdMs: 40),
      ]);
      expect(computeDailyScore(days, target), isNull);
    });

    test('sleep unavailable with only 6 prior nights', () {
      final days = _mapOf([
        for (final d in _priorDates(target, 6))
          DailyBiometrics(date: d, sleepMinutes: 480),
        const DailyBiometrics(date: target, sleepMinutes: 480),
      ]);
      expect(computeDailyScore(days, target), isNull);
    });

    test('no available component: null score (cold start)', () {
      final days = _mapOf([
        const DailyBiometrics(date: target, caloriesKcal: 2000),
      ]);
      expect(computeDailyScore(days, target), isNull);
      expect(computeDailyScore(days, '2026-01-01'), isNull);
    });

    test('baseline window is the most recent 28 days with data', () {
      // 20 older days at 20 ms, then 15 newer days at 60 ms. The
      // most-recent-28 window = 13x20 + 15x60 → median 60, so a
      // 60 ms day sits AT baseline (70). Using all 35 days would
      // give median 20 and a saturated 100.
      final priors = _priorDates(target, 35);
      final days = _mapOf([
        for (var i = 0; i < priors.length; i++)
          DailyBiometrics(
              date: priors[i], hrvRmssdMs: i < 20 ? 20 : 60),
        const DailyBiometrics(date: target, hrvRmssdMs: 60),
      ]);
      expect(computeDailyScore(days, target)!.hrvScore, 70);
    });

    test('baseline counts days strictly before the scored day', () {
      // Only 6 prior HRV days; a LATER day carrying HRV must not
      // complete the baseline.
      final days = _mapOf([
        for (final d in _priorDates(target, 6))
          DailyBiometrics(date: d, hrvRmssdMs: 40),
        const DailyBiometrics(date: target, hrvRmssdMs: 40),
        const DailyBiometrics(date: '2026-10-18', hrvRmssdMs: 40),
      ]);
      expect(computeDailyScore(days, target), isNull);
    });
  });

  group('store: score persistence', () {
    late _FakeStore fake;
    late HealthHistoryStore store;

    setUp(() {
      fake = _FakeStore();
      store = _fakeStore(fake);
    });

    test('older blob without score keys loads with null scores', () async {
      fake.values[HealthHistoryStore.storageKey] = jsonEncode({
        'ownerEmail': null,
        'lastCaptureMs': null,
        'days': {
          '2026-10-01': {'date': '2026-10-01', 'restingHrBpm': 60},
        },
      });
      final all = await store.readAll();
      expect(all['2026-10-01']!.restingHrBpm, 60);
      expect(all['2026-10-01']!.dailyScore, isNull);
      expect(all['2026-10-01']!.scoreSleep, isNull);
    });

    test('score round-trips through the blob, including a 0 score',
        () async {
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ]);
      final ok = await store.persistScore('2026-10-01',
          dailyScore: 0, scoreSleep: 0);
      expect(ok, isTrue);
      final reloaded = _fakeStore(fake);
      final all = await reloaded.readAll();
      expect(all['2026-10-01']!.dailyScore, 0);
      expect(all['2026-10-01']!.scoreSleep, 0);
      expect(all['2026-10-01']!.scoreHrv, isNull);
    });

    test('persistScore refuses a missing day and a scored day', () async {
      expect(await store.persistScore('2026-10-01', dailyScore: 50), isFalse);
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ]);
      expect(await store.persistScore('2026-10-01', dailyScore: 50), isTrue);
      expect(await store.persistScore('2026-10-01', dailyScore: 99), isFalse);
      final all = await store.readAll();
      expect(all['2026-10-01']!.dailyScore, 50);
    });

    test('merges never touch score fields', () async {
      await store.mergeRefresh([
        const DailyBiometrics(
            date: '2026-10-01', restingHrBpm: 60, sleepMinutes: 400),
      ]);
      await store.persistScore('2026-10-01',
          dailyScore: 72, scoreSleep: 80, scoreRestingHr: 60);

      // A capture row that CHANGES biometrics and (maliciously /
      // accidentally) carries score values of its own.
      final bogus = const DailyBiometrics(
              date: '2026-10-01', restingHrBpm: 61, caloriesKcal: 2100)
          .withScores(
              dailyScore: 5, scoreSleep: 5, scoreHrv: 5, scoreRestingHr: 5);
      await store.mergeRefresh([bogus]);
      var row = (await store.readAll())['2026-10-01']!;
      expect(row.restingHrBpm, 61); // refresh still wins on biometrics
      expect(row.dailyScore, 72); // scores untouched
      expect(row.scoreSleep, 80);
      expect(row.scoreHrv, isNull);
      expect(row.scoreRestingHr, 60);

      await store.mergeFillGaps([bogus]);
      row = (await store.readAll())['2026-10-01']!;
      expect(row.dailyScore, 72);
      expect(row.scoreHrv, isNull);

      // A brand-new day inserted by a merge drops incoming scores.
      final bogusNew = const DailyBiometrics(date: '2026-10-02', restingHrBpm: 58)
          .withScores(
              dailyScore: 5, scoreSleep: 5, scoreHrv: 5, scoreRestingHr: 5);
      await store.mergeRefresh([bogusNew]);
      final newRow = (await store.readAll())['2026-10-02']!;
      expect(newRow.restingHrBpm, 58);
      expect(newRow.dailyScore, isNull);
      expect(newRow.scoreSleep, isNull);
    });
  });

  group('engine: write-once freeze against baseline drift', () {
    test('a scored day never changes when earlier data drifts', () async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      const target = '2026-10-17';
      final priors = _priorDates(target, 28);
      await store.mergeRefresh([
        for (final d in priors) DailyBiometrics(date: d, restingHrBpm: 60),
        const DailyBiometrics(date: target, restingHrBpm: 54),
      ]);
      final engine = DailyScoreEngine(store: store);
      final written = await engine.computeMissingScores();
      expect(written, greaterThan(0));
      var all = await store.readAll();
      expect(all[target]!.dailyScore, 100); // RHR-only, saturated
      expect(all[target]!.scoreRestingHr, 100);
      expect(all[target]!.scoreSleep, isNull);
      final frozenTarget = all[target];

      // Baseline drift: every prior day's resting HR changes
      // (60 → 50 puts the target's 54 at +8% above baseline, which
      // WOULD score 42 — outside the -10% saturation zone, so the
      // freeze check below is not vacuous).
      await store.mergeRefresh([
        for (final d in priors) DailyBiometrics(date: d, restingHrBpm: 50),
      ]);
      // A fresh computation on the drifted data WOULD differ —
      // proving the freeze below is what protects the record.
      final drifted = await store.readAll();
      expect(computeDailyScore(drifted, target)!.dailyScore, isNot(100));

      final rewritten = await engine.computeMissingScores();
      expect(rewritten, 0);
      all = await store.readAll();
      expect(all[target], frozenTarget);
      expect(all[target]!.dailyScore, 100);
    });

    test('engine scores nothing when no baseline exists yet', () async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      await store.mergeRefresh([
        const DailyBiometrics(
            date: '2026-10-17', restingHrBpm: 60, hrvRmssdMs: 40),
      ]);
      final written =
          await DailyScoreEngine(store: store).computeMissingScores();
      expect(written, 0);
      expect((await store.readAll())['2026-10-17']!.dailyScore, isNull);
    });
  });

  group('bands + component chips (concept vocabulary)', () {
    test('band boundaries', () {
      expect(bandForScore(100).label, 'Great');
      expect(bandForScore(80).label, 'Great');
      expect(bandForScore(79).label, 'Good');
      expect(bandForScore(60).label, 'Good');
      expect(bandForScore(59).label, 'Low');
      expect(bandForScore(40).label, 'Low');
      expect(bandForScore(39).label, 'Very low');
      expect(bandForScore(0).label, 'Very low');
    });

    test('sleep chip follows the component score', () {
      expect(sleepChipForScore(89).label, 'Good');
      expect(sleepChipForScore(70).label, 'Normal');
      expect(sleepChipForScore(50).label, 'Low');
      expect(sleepChipForScore(20).label, 'Very low');
    });

    test('direction chips use the ±2% Normal deadband', () {
      expect(hrvChipForDeviation(12.5).label, 'Above');
      expect(hrvChipForDeviation(1.5).label, 'Normal');
      expect(hrvChipForDeviation(-20).label, 'Below');
      expect(restingHrChipForDeviation(0).label, 'Normal');
      expect(restingHrChipForDeviation(-10).label, 'Below');
      expect(restingHrChipForDeviation(8).label, 'Above');
    });
  });

  group('widgets: score circle', () {
    testWidgets('scored circle renders number + label + band chip',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: DailyScoreCircle(score: 72)),
      ));
      expect(find.text('72'), findsOneWidget);
      expect(find.text('Daily Score'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
    });

    testWidgets('building state renders a dash and no number', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: DailyScoreCircle(score: null)),
        ),
      ));
      expect(find.text('--'), findsOneWidget);
      expect(find.text('Building'), findsOneWidget);
      // No numeric score anywhere in the building state.
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        expect(int.tryParse(t.data ?? ''), isNull,
            reason: 'building state must not render a number');
      }
    });
  });

  group('widgets: history + detail', () {
    // 28 baseline days of resting HR 60 (Sep 18 – Oct 15, 2026),
    // target day Oct 16 at 54 (RHR-only score, saturated 100).
    Future<HealthHistoryStore> seededStore() async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      await store.mergeRefresh([
        for (final d in _priorDates('2026-10-16', 28))
          DailyBiometrics(date: d, restingHrBpm: 60),
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 54),
      ]);
      await DailyScoreEngine(store: store).computeMissingScores();
      return store;
    }

    testWidgets('history lists scored days incl. a partial-component day',
        (tester) async {
      final store = await seededStore();
      await tester.pumpWidget(MaterialApp(home: DailyScoreScreen(store: store)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // The concept's 14-day chart card.
      expect(find.text('Last 14 days'), findsOneWidget);
      // Newest scored day first: Oct 16, 2026 was a Friday.
      expect(find.text('Fri, Oct 16'), findsOneWidget);
      expect(find.text('100'), findsWidgets);
      // Every scored day here is a partial-component day (resting
      // heart rate only): the component line names it alone, and
      // no row shows a multi-component " · "-joined line.
      expect(find.text('Resting heart rate'), findsWidgets);
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('day detail shows inputs vs baselines + counted parts',
        (tester) async {
      final store = await seededStore();
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreDayScreen(store: store, date: '2026-10-16'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // The concept's day chip + the resting-HR direction chip
      // (54 vs a 60 baseline is 10% below → "Below").
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      expect(find.text('Below'), findsOneWidget);
      expect(find.text('54 bpm · your baseline 60 bpm'), findsOneWidget);
      expect(find.text('No sleep stored for this night.'), findsOneWidget);
      expect(find.text('No HRV reading stored for this day.'), findsOneWidget);
      expect(find.text('Not counted'), findsNWidgets(2));
      // Trend vs the previous scored day (Oct 15 scored 70).
      expect(find.textContaining('Higher by 30'), findsOneWidget);
    });

    testWidgets('empty store renders the building state, no numbers',
        (tester) async {
      final store = _fakeStore(_FakeStore());
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: DailyScoreScreen(store: store),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Building baseline'), findsWidgets);
      expect(find.text('How this score works'), findsOneWidget);
    });
  });

  group('widgets: Home header', () {
    testWidgets('score circle appears beside the weather icon with today\'s '
        'persisted score', (tester) async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      final today = DateTime.now();
      final todayStr = _ds(DateTime(today.year, today.month, today.day));
      await store.mergeRefresh([
        for (final d in _priorDates(todayStr, 28))
          DailyBiometrics(date: d, restingHrBpm: 60),
        DailyBiometrics(date: todayStr, restingHrBpm: 54),
      ]);
      // R70 fix pass (Vera F2) — TODAY RULE: Home's own trigger is
      // cut off before today, so today's score must already be
      // PERSISTED (this test's name) by the post-capture engine run.
      // Simulate that run here (no cutoff) before pumping Home.
      await DailyScoreEngine(store: store).computeMissingScores();
      expect((await store.readAll())[todayStr]!.dailyScore, 100);
      final mockWeather = MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
        }
        return http.Response(
            '{"current":{"temperature_2m":55.0,"weather_code":2,"is_day":1}}',
            200);
      });
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: WeatherApiClient(client: mockWeather),
          healthHistoryStore: store,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byType(DailyScoreCircle), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
      expect(find.text('Great'), findsOneWidget);
    });
  });
}
