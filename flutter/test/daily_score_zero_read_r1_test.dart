import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';

/// R1 regression guard — the founder's biometric zero rule, proven
/// END TO END through the Daily Score computation.
///
/// The standing rule (Tyson, Oct 2026): a 0 in biometric data (HRV,
/// resting heart rate, sleep) is NEVER a real value — it is a
/// failed read and must be treated as MISSING: never stored,
/// charted, averaged, or fed into the Daily Score.
///
/// Before this file, that rule was proven only at the storage
/// level for HRV (`health_history_r70_test.dart`: "zero rule:
/// 0/negative never stored, never erase; spike 0 stored") and for
/// Sleep Need's night counting
/// (`health_history_queries_r70_test.dart`). Nothing asserted what
/// happens when a 0 sample is submitted for a day that then goes
/// through scoring — the R1 hygiene gap from the Oct 27, 2026
/// regression run.
///
/// THE REAL SCORING PATH (the same one the app uses, driven here
/// at the highest layer the existing harness supports):
///
///   1. `HealthHistoryStore.mergeRefresh` — the Health Connect
///      capture merge every incoming sample passes through; it
///      applies `DailyBiometrics.sanitized()` on the way in.
///   2. `HealthHistoryStore.readAll` — the store map the engine
///      reads.
///   3. `computeDailyScore(days, date)` — the pure computation
///      (sleep 40 / HRV 35 / resting HR 25, weights renormalized
///      over the AVAILABLE components; a component counts only
///      with ≥ [baselineMinDays] baseline days from the most
///      recent [baselineWindowDays] days with data strictly
///      before the scored day).
///   4. `DailyScoreEngine.computeMissingScores` — the engine's
///      write-once persistence of the computed components.
///
/// Every test below feeds its samples through ALL FOUR steps and
/// asserts on both the computation object (step 3) and the
/// persisted store row (step 4). A 0 sample for a component must
/// produce a MISSING component for that day: the component is
/// excluded, the score is the renormalized weighted mean of the
/// remaining components, and the persisted component field stays
/// null. Each target-day test also pins the counterfactual value
/// the day WOULD score if 0 were (wrongly) treated as a measured
/// value, so the guard cannot pass vacuously.
///
/// Sample-type coverage: HRV, resting HR, and sleep are ALL driven
/// through this same path — the store, computation, and engine
/// treat the three identically, so no sample type needed a
/// substitute route.

/// In-memory fake for the store's storage functions (the
/// `_FakeStore` pattern from `daily_score_r70_test.dart`).
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

HealthHistoryStore _fakeStore(_FakeStore fake) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return store;
}

/// One full baseline day: sleep at a stable 480, HRV at 40 ms,
/// resting HR at 60 bpm — every baseline median/need below is
/// built from exactly these values.
DailyBiometrics _baselineDay(String date) => DailyBiometrics(
      date: date,
      sleepMinutes: 480,
      hrvRmssdMs: 40,
      restingHrBpm: 60,
    );

/// The same baseline day as a persisted-JSON row (the shape
/// `DailyBiometrics.toJson` writes inside the disk blob).
Map<String, dynamic> _jsonBaselineDay(String date) => {
      'date': date,
      'sleepMinutes': 480,
      'hrvRmssdMs': 40,
      'restingHrBpm': 60,
    };

/// A persisted blob string shaped exactly like
/// `HealthHistoryStore.persist()` writes it.
String _persistedBlob(Map<String, Map<String, dynamic>> days) =>
    jsonEncode({
      'ownerEmail': 'founder@tabs.app',
      'lastCaptureMs': 1234567890,
      'days': days,
    });

/// A store whose disk ALREADY holds [days] as a persisted blob
/// before the store exists: the blob is placed in the fake
/// storage BEFORE the store is created via [_fakeStore], and
/// nothing is ever merged — the first store interaction in
/// these tests is the cold `readAll()`, which lazily warms from
/// disk through `warmFromDisk` → `DailyBiometrics.fromJson`.
HealthHistoryStore _coldStore(Map<String, Map<String, dynamic>> days) {
  final fake = _FakeStore();
  fake.values[HealthHistoryStore.storageKey] = _persistedBlob(days);
  return _fakeStore(fake);
}

void main() {
  const target = '2026-10-17';

  group('R1 E2E: 0 HRV sample through store + engine', () {
    test('target day: 0 HRV is a MISSING HRV component, and the '
        'score renormalizes over sleep + resting HR', () async {
      final store = _fakeStore(_FakeStore());
      await store.mergeRefresh([
        for (final d in _priorDates(target, 28)) _baselineDay(d),
        // The day under test: a real short night, a real resting
        // HR at baseline — and an HRV sample of 0 ms (failed read).
        const DailyBiometrics(
          date: target,
          sleepMinutes: 240,
          hrvRmssdMs: 0,
          restingHrBpm: 60,
        ),
      ]);

      // Step 2/3: the store map the engine reads holds NO HRV for
      // the day, and the computation excludes the component.
      final days = await store.readAll();
      expect(days[target]!.hrvRmssdMs, isNull,
          reason: 'a 0 ms HRV sample must arrive at the score '
              'computation as missing, never as a stored 0');
      final c = computeDailyScore(days, target)!;
      expect(c.hrvScore, isNull);
      expect(c.hrvMs, isNull);
      expect(c.hrvBaselineMs, isNull);
      expect(c.hasAllComponents, isFalse);
      // Remaining components score exactly as in the established
      // fixtures: sleep 240 vs a 480 need = ratio 0.5, squared →
      // 25; resting HR at its 60 bpm baseline median = 70.
      expect(c.sleepScore, 25);
      expect(c.restingHrScore, 70);
      // Renormalized over the available weights only:
      // (40·25 + 25·70) / 65 = 42.31…
      expect(c.dailyExact, closeTo(42.308, 0.001));
      expect(c.dailyScore, 42);
      // Counterfactual pin: had 0 been treated as measured, the
      // HRV component would clamp to 0 (dev −100%) and drag the
      // day to (40·25 + 35·0 + 25·70) / 100 = 27.5 → 28.
      expect(c.dailyScore, isNot(28),
          reason: '28 is the score a measured-0 HRV would produce');

      // Step 4: the engine persists the same exclusion — the HRV
      // component field stays null on the scored day.
      await DailyScoreEngine(store: store).computeMissingScores();
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, 42);
      expect(persisted.scoreSleep, 25);
      expect(persisted.scoreHrv, isNull);
      expect(persisted.scoreRestingHr, 70);
    });

    test('baseline: 0 HRV days never count toward the ≥7 baseline '
        'days, so the component stays unavailable', () async {
      final store = _fakeStore(_FakeStore());
      final priors = _priorDates(target, 16);
      await store.mergeRefresh([
        // Oldest 6 prior days: real HRV at 40 ms.
        for (final d in priors.sublist(0, 6))
          DailyBiometrics(date: d, hrvRmssdMs: 40, caloriesKcal: 2000),
        // Most recent 10 prior days: HRV read FAILED (0 ms) — each
        // day exists in the store only via a real calories value.
        for (final d in priors.sublist(6))
          DailyBiometrics(date: d, hrvRmssdMs: 0, caloriesKcal: 2000),
        const DailyBiometrics(date: target, hrvRmssdMs: 40),
      ]);
      final days = await store.readAll();
      // The failed-read days are present but carry no HRV.
      expect(days[priors.last]!.hrvRmssdMs, isNull);
      // Only 6 real baseline days exist (< 7): no HRV component,
      // and with no other component present, no score at all. If
      // the 0 days counted as baseline days, a baseline (median
      // over the zeros) would exist and a number would appear.
      expect(computeDailyScore(days, target), isNull);
      final written =
          await DailyScoreEngine(store: store).computeMissingScores();
      expect(written, 0);
      expect((await store.readAll())[target]!.dailyScore, isNull);
    });

    test('baseline: 0 HRV days neither dilute the median nor '
        'consume window slots — 7 real days behind them still '
        'form the baseline', () async {
      final store = _fakeStore(_FakeStore());
      final priors = _priorDates(target, 28);
      await store.mergeRefresh([
        // Oldest 7 prior days: real HRV at 40 ms.
        for (final d in priors.sublist(0, 7))
          DailyBiometrics(date: d, hrvRmssdMs: 40, caloriesKcal: 2000),
        // The 21 most recent prior days: failed HRV reads (0 ms).
        for (final d in priors.sublist(7))
          DailyBiometrics(date: d, hrvRmssdMs: 0, caloriesKcal: 2000),
        const DailyBiometrics(date: target, hrvRmssdMs: 40),
      ]);
      final days = await store.readAll();
      final c = computeDailyScore(days, target)!;
      // Baseline is the 7 real 40 ms days: a 40 ms day sits AT
      // baseline (70). Counting the zeros would put the median
      // at 0 and the day nowhere near 70.
      expect(c.hrvBaselineMs, 40);
      expect(c.hrvScore, 70);
      expect(c.dailyScore, 70);
      await DailyScoreEngine(store: store).computeMissingScores();
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, 70);
      expect(persisted.scoreHrv, 70);
    });
  });

  group('R1 E2E: 0 resting-HR sample through store + engine', () {
    test('target day: 0 bpm is a MISSING resting-HR component, '
        'and the score renormalizes over sleep + HRV', () async {
      final store = _fakeStore(_FakeStore());
      await store.mergeRefresh([
        for (final d in _priorDates(target, 28)) _baselineDay(d),
        const DailyBiometrics(
          date: target,
          sleepMinutes: 240,
          hrvRmssdMs: 40,
          restingHrBpm: 0,
        ),
      ]);
      final days = await store.readAll();
      expect(days[target]!.restingHrBpm, isNull,
          reason: 'a 0 bpm resting-HR sample must arrive at the '
              'score computation as missing, never as a stored 0');
      final c = computeDailyScore(days, target)!;
      expect(c.restingHrScore, isNull);
      expect(c.restingHrBpm, isNull);
      expect(c.restingHrBaselineBpm, isNull);
      expect(c.hasAllComponents, isFalse);
      expect(c.sleepScore, 25);
      expect(c.hrvScore, 70); // 40 ms at the 40 ms baseline median
      // Sleep ratio 0.5 squared → 25: (40·25 + 35·70) / 75 = 46.
      expect(c.dailyExact, closeTo(46, 0.001));
      expect(c.dailyScore, 46);
      // Counterfactual pin: a measured 0 bpm is −100% vs baseline,
      // which the INVERTED resting-HR map saturates at 100, giving
      // (40·25 + 35·70 + 25·100) / 100 = 59.5 → 60 — a failed read
      // would INFLATE the score if it were ever treated as data.
      expect(c.dailyScore, isNot(60),
          reason: '60 is the score a measured-0 resting HR would '
              'produce through the inverted map');

      await DailyScoreEngine(store: store).computeMissingScores();
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, 46);
      expect(persisted.scoreSleep, 25);
      expect(persisted.scoreHrv, 70);
      expect(persisted.scoreRestingHr, isNull);
    });

    test('baseline: 0 resting-HR days never count toward the ≥7 '
        'baseline days', () async {
      final store = _fakeStore(_FakeStore());
      final priors = _priorDates(target, 16);
      await store.mergeRefresh([
        for (final d in priors.sublist(0, 6))
          DailyBiometrics(date: d, restingHrBpm: 60, caloriesKcal: 2000),
        for (final d in priors.sublist(6))
          DailyBiometrics(date: d, restingHrBpm: 0, caloriesKcal: 2000),
        const DailyBiometrics(date: target, restingHrBpm: 60),
      ]);
      final days = await store.readAll();
      expect(days[priors.last]!.restingHrBpm, isNull);
      // 6 real baseline days < 7 → component unavailable → no
      // score (no other component is present on the target day).
      expect(computeDailyScore(days, target), isNull);
      final written =
          await DailyScoreEngine(store: store).computeMissingScores();
      expect(written, 0);
      expect((await store.readAll())[target]!.dailyScore, isNull);
    });
  });

  group('R1 E2E: 0 sleep sample through store + engine', () {
    test('target day: 0 sleep minutes is a MISSING sleep '
        'component, and the score renormalizes over HRV + '
        'resting HR', () async {
      final store = _fakeStore(_FakeStore());
      await store.mergeRefresh([
        for (final d in _priorDates(target, 28)) _baselineDay(d),
        const DailyBiometrics(
          date: target,
          sleepMinutes: 0,
          hrvRmssdMs: 40,
          restingHrBpm: 60,
        ),
      ]);
      final days = await store.readAll();
      expect(days[target]!.sleepMinutes, isNull,
          reason: 'a 0-minute sleep sample must arrive at the '
              'score computation as a night with no data, never '
              'as a night of 0 sleep');
      final c = computeDailyScore(days, target)!;
      expect(c.sleepScore, isNull);
      expect(c.asleepMinutes, isNull);
      expect(c.sleepNeedMinutes, isNull);
      expect(c.hasAllComponents, isFalse);
      expect(c.hrvScore, 70);
      expect(c.restingHrScore, 70);
      // (35·70 + 25·70) / 60 = 70 exactly.
      expect(c.dailyScore, 70);
      // Counterfactual pin: a measured 0-minute night scores a
      // sleep component of 0 (ratio 0 / need), giving
      // (40·0 + 35·70 + 25·70) / 100 = 42.
      expect(c.dailyScore, isNot(42),
          reason: '42 is the score a measured-0 sleep night would '
              'produce');

      await DailyScoreEngine(store: store).computeMissingScores();
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, 70);
      expect(persisted.scoreSleep, isNull);
      expect(persisted.scoreHrv, 70);
      expect(persisted.scoreRestingHr, 70);
    });

    test('history: 0-minute nights never count toward the ≥7 '
        'prior nights a Sleep Need estimate requires', () async {
      final store = _fakeStore(_FakeStore());
      final priors = _priorDates(target, 16);
      await store.mergeRefresh([
        // Oldest 6 prior nights: real sleep at 480.
        for (final d in priors.sublist(0, 6))
          DailyBiometrics(date: d, sleepMinutes: 480, caloriesKcal: 2000),
        // Most recent 10 prior "nights": failed reads (0 minutes),
        // present in the store only via a real calories value.
        for (final d in priors.sublist(6))
          DailyBiometrics(date: d, sleepMinutes: 0, caloriesKcal: 2000),
        const DailyBiometrics(date: target, sleepMinutes: 240),
      ]);
      final days = await store.readAll();
      expect(days[priors.last]!.sleepMinutes, isNull);
      // Only 6 real prior nights exist (< 7): no need estimate,
      // no sleep component, and no other component is present —
      // so no score. Counting the 0 nights as nights would have
      // produced a need and a number.
      expect(computeDailyScore(days, target), isNull);
      final written =
          await DailyScoreEngine(store: store).computeMissingScores();
      expect(written, 0);
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, isNull);
      expect(persisted.scoreSleep, isNull);
    });

    test('history: 0-minute nights create no sleep debt and do '
        'not inflate the target night\'s Sleep Need', () async {
      final store = _fakeStore(_FakeStore());
      final priors = _priorDates(target, 15);
      await store.mergeRefresh([
        // Oldest 10 prior nights: real sleep at 480.
        for (final d in priors.sublist(0, 10))
          DailyBiometrics(date: d, sleepMinutes: 480, caloriesKcal: 2000),
        // The 5 most recent prior nights: failed reads (0 minutes).
        for (final d in priors.sublist(10))
          DailyBiometrics(date: d, sleepMinutes: 0, caloriesKcal: 2000),
        const DailyBiometrics(date: target, sleepMinutes: 480),
      ]);
      final c = computeDailyScore((await store.readAll()), target)!;
      // Need from the real nights alone = 480, no debt: a 480
      // night meets its need exactly → sleep component 100.
      // Counting the 0 nights would add 5 × 480 of "debt" (need
      // capped at 480 + 120 = 600) and score the night at ratio
      // 480/600 = 0.8, squared → 64.
      expect(c.sleepNeedMinutes, 480);
      expect(c.sleepScore, 100);
      expect(c.dailyScore, 100);
      expect(c.dailyScore, isNot(64),
          reason: '64 is the score if 0-minute nights counted '
              'as debt-bearing nights');
    });
  });

  group('R1 E2E: a day whose samples ALL read 0', () {
    test('no component, no score — even with a full baseline '
        'behind it and a real spike count of 0 on the day',
        () async {
      final store = _fakeStore(_FakeStore());
      await store.mergeRefresh([
        for (final d in _priorDates(target, 28)) _baselineDay(d),
        // Every biometric read failed (0); spikeCount 0 is REAL
        // data (a sampled day with no spikes — the store's one
        // zero exception), so the day itself exists in the store.
        const DailyBiometrics(
          date: target,
          sleepMinutes: 0,
          hrvRmssdMs: 0,
          restingHrBpm: 0,
          spikeCount: 0,
        ),
      ]);
      final days = await store.readAll();
      final row = days[target]!;
      expect(row.spikeCount, 0); // real data, stored as 0
      expect(row.sleepMinutes, isNull);
      expect(row.hrvRmssdMs, isNull);
      expect(row.restingHrBpm, isNull);
      // A full 28-day baseline exists for every component, yet
      // there is nothing to score: the honest no-score state.
      expect(computeDailyScore(days, target), isNull);
      await DailyScoreEngine(store: store).computeMissingScores();
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, isNull);
      expect(persisted.scoreSleep, isNull);
      expect(persisted.scoreHrv, isNull);
      expect(persisted.scoreRestingHr, isNull);
    });
  });

  group('R1 cold-load: 0 values in the persisted JSON blob '
      '(fromJson path)', () {
    test('target day: persisted hrvRmssdMs 0 warms as MISSING, '
        'and the score renormalizes over sleep + resting HR',
        () async {
      final store = _coldStore({
        for (final d in _priorDates(target, 28)) d: _jsonBaselineDay(d),
        target: {
          'date': target,
          'sleepMinutes': 240,
          'hrvRmssdMs': 0,
          'restingHrBpm': 60,
        },
      });

      // The FIRST interaction is the cold warm itself.
      final days = await store.readAll();
      expect(days[target]!.hrvRmssdMs, isNull,
          reason: 'a persisted 0 ms HRV must warm from disk as '
              'missing (fromJson zero rule), never as a stored 0');
      final c = computeDailyScore(days, target)!;
      expect(c.hrvScore, isNull);
      expect(c.sleepScore, 25);
      expect(c.restingHrScore, 70);
      expect(c.dailyScore, 42);
      expect(c.dailyScore, isNot(28),
          reason: '28 is the score a measured-0 HRV would produce');

      await DailyScoreEngine(store: store).computeMissingScores();
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, 42);
      expect(persisted.scoreHrv, isNull);
      expect(persisted.scoreSleep, 25);
      expect(persisted.scoreRestingHr, 70);
    });

    test('target day: persisted restingHrBpm 0 warms as MISSING, '
        'and the score renormalizes over sleep + HRV', () async {
      final store = _coldStore({
        for (final d in _priorDates(target, 28)) d: _jsonBaselineDay(d),
        target: {
          'date': target,
          'sleepMinutes': 240,
          'hrvRmssdMs': 40,
          'restingHrBpm': 0,
        },
      });

      final days = await store.readAll();
      expect(days[target]!.restingHrBpm, isNull,
          reason: 'a persisted 0 bpm resting HR must warm from '
              'disk as missing (fromJson zero rule)');
      final c = computeDailyScore(days, target)!;
      expect(c.restingHrScore, isNull);
      expect(c.sleepScore, 25);
      expect(c.hrvScore, 70);
      expect(c.dailyScore, 46);
      expect(c.dailyScore, isNot(60),
          reason: '60 is the score a measured-0 resting HR would '
              'produce through the inverted map');

      await DailyScoreEngine(store: store).computeMissingScores();
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, 46);
      expect(persisted.scoreRestingHr, isNull);
      expect(persisted.scoreSleep, 25);
      expect(persisted.scoreHrv, 70);
    });

    test('target day: persisted sleepMinutes 0 warms as MISSING, '
        'and the score renormalizes over HRV + resting HR',
        () async {
      final store = _coldStore({
        for (final d in _priorDates(target, 28)) d: _jsonBaselineDay(d),
        target: {
          'date': target,
          'sleepMinutes': 0,
          'hrvRmssdMs': 40,
          'restingHrBpm': 60,
        },
      });

      final days = await store.readAll();
      expect(days[target]!.sleepMinutes, isNull,
          reason: 'a persisted 0-minute sleep must warm from '
              'disk as a night with no data (fromJson zero rule)');
      final c = computeDailyScore(days, target)!;
      expect(c.sleepScore, isNull);
      expect(c.hrvScore, 70);
      expect(c.restingHrScore, 70);
      expect(c.dailyScore, 70);
      expect(c.dailyScore, isNot(42),
          reason: '42 is the score a measured-0 sleep night '
              'would produce');

      await DailyScoreEngine(store: store).computeMissingScores();
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, 70);
      expect(persisted.scoreSleep, isNull);
      expect(persisted.scoreHrv, 70);
      expect(persisted.scoreRestingHr, 70);
    });

    test('baseline: persisted 0 HRV days warm with no HRV and '
        'never count toward the ≥7 baseline days', () async {
      final priors = _priorDates(target, 16);
      final store = _coldStore({
        // Oldest 6 prior days: real HRV at 40 ms.
        for (final d in priors.sublist(0, 6))
          d: {'date': d, 'hrvRmssdMs': 40, 'caloriesKcal': 2000},
        // Most recent 10 prior days: persisted HRV of 0 ms
        // (failed reads) — each day exists only via calories.
        for (final d in priors.sublist(6))
          d: {'date': d, 'hrvRmssdMs': 0, 'caloriesKcal': 2000},
        target: {'date': target, 'hrvRmssdMs': 40},
      });

      final days = await store.readAll();
      // The zero days arrived, but with no HRV value.
      expect(days[priors.last]!.hrvRmssdMs, isNull,
          reason: 'a persisted 0 ms HRV day must warm with '
              'hrvRmssdMs null (fromJson zero rule)');
      // Only 6 real baseline days exist (< 7): no HRV component,
      // and with no other component present, no score at all.
      expect(computeDailyScore(days, target), isNull);
      final written =
          await DailyScoreEngine(store: store).computeMissingScores();
      expect(written, 0);
      expect((await store.readAll())[target]!.dailyScore, isNull);
    });

    test('a day whose persisted biometrics ALL read 0: spike 0 '
        'survives as real data, the three biometrics warm null, '
        'and no score is computed or persisted', () async {
      final store = _coldStore({
        for (final d in _priorDates(target, 28)) d: _jsonBaselineDay(d),
        target: {
          'date': target,
          'sleepMinutes': 0,
          'hrvRmssdMs': 0,
          'restingHrBpm': 0,
          'spikeCount': 0,
        },
      });

      final days = await store.readAll();
      final row = days[target]!;
      expect(row.spikeCount, 0,
          reason: 'spikeCount 0 is real data and survives the '
              'cold load — it is the store\'s one zero exception');
      expect(row.sleepMinutes, isNull);
      expect(row.hrvRmssdMs, isNull);
      expect(row.restingHrBpm, isNull);
      // A full 28-day baseline exists, yet there is nothing to
      // score: the honest no-score state.
      expect(computeDailyScore(days, target), isNull);
      await DailyScoreEngine(store: store).computeMissingScores();
      final persisted = (await store.readAll())[target]!;
      expect(persisted.dailyScore, isNull);
      expect(persisted.scoreSleep, isNull);
      expect(persisted.scoreHrv, isNull);
      expect(persisted.scoreRestingHr, isNull);
    });
  });
}
