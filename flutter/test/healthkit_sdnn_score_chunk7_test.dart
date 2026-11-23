import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';

/// HealthKit chunk 7 — the Daily Score SDNN adaptation (founder
/// decision e-3, Option 1: SDNN vs personal baselines for iOS v1):
/// - an SDNN-only day (iOS) scores its HRV component from
///   `hrvSdnnMs` against a baseline drawn ONLY from SDNN days —
///   same weight (35), same anchors, same baseline window/minimum
///   as the RMSSD path; the ONLY difference is the input series;
/// - the series are never mixed: an SDNN day with no SDNN
///   baseline (however rich the RMSSD history) has NO HRV
///   component, exactly like an Android day with no RMSSD
///   baseline, and baselines rebuild after a platform switch;
/// - a day carrying BOTH series scores from RMSSD (Android
///   precedence — the RMSSD computation is unchanged);
/// - the gate keys off the DATA (which series a day carries),
///   never a platform/UI context: `computeDailyScore` takes no
///   platform argument, so foreground, refresher, post-capture
///   engine and background paths all agree;
/// - labels: a persisted SDNN-sourced component is named
///   "HRV (SDNN)"; RMSSD reads "HRV (RMSSD)".

class MemorySecureStore implements SecureStore {
  final Map<String, String> map = {};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async {
    map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    map.remove(key);
  }
}

const _channelName = 'com.notel.notel.playground.flutter/health_connect';

HealthHistoryStore _storeFor(Map<String, String> disk) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  return store;
}

String _ds(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// [count] consecutive dates ending the day BEFORE [anchor].
List<String> _priorDates(String anchor, int count) {
  final a = DateTime.parse(anchor);
  return [
    for (var i = count; i >= 1; i--) _ds(a.subtract(Duration(days: i))),
  ];
}

Map<String, DailyBiometrics> _mapOf(Iterable<DailyBiometrics> rows) =>
    {for (final r in rows) r.date: r};

/// Priors with sleep + resting HR held constant (so those
/// components sit at their baseline scores) and HRV in ONE
/// series, plus the target day in the same series.
Map<String, DailyBiometrics> _seriesDays({
  required String target,
  required int priorCount,
  required double priorHrv,
  required double targetHrv,
  required bool sdnn,
}) {
  DailyBiometrics row(String date, double hrv) => DailyBiometrics(
        date: date,
        sleepMinutes: 480,
        restingHrBpm: 60,
        hrvRmssdMs: sdnn ? null : hrv,
        hrvSdnnMs: sdnn ? hrv : null,
      );
  return _mapOf([
    for (final d in _priorDates(target, priorCount)) row(d, priorHrv),
    row(target, targetHrv),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
    HealthHistorySync.debugResetFlight();
  });

  group('SDNN scoring (iOS days)', () {
    const target = '2026-11-20';

    test('an SDNN-only day WITH an SDNN baseline scores its HRV '
        'component from SDNN', () {
      final days = _seriesDays(
          target: target,
          priorCount: 10,
          priorHrv: 50,
          targetHrv: 50,
          sdnn: true);
      final c = computeDailyScore(days, target)!;
      // At the baseline median the anchor score is 70 — the same
      // anchor the RMSSD path uses.
      expect(c.hrvScore, 70);
      expect(c.hrvMs, 50);
      expect(c.hrvBaselineMs, 50);
      expect(c.hrvFromSdnn, isTrue);
      expect(c.hasAllComponents, isTrue);
    });

    test('deviation mapping is identical: +25% over the SDNN '
        'baseline scores 100, −40% scores 0', () {
      final up = computeDailyScore(
          _seriesDays(
              target: target,
              priorCount: 10,
              priorHrv: 50,
              targetHrv: 62.5,
              sdnn: true),
          target)!;
      expect(up.hrvScore, 100);
      final down = computeDailyScore(
          _seriesDays(
              target: target,
              priorCount: 10,
              priorHrv: 50,
              targetHrv: 30,
              sdnn: true),
          target)!;
      expect(down.hrvScore, 0);
    });

    test('parity: identical numbers in RMSSD and SDNN produce '
        'identical component and daily scores', () {
      final rmssd = computeDailyScore(
          _seriesDays(
              target: target,
              priorCount: 10,
              priorHrv: 44,
              targetHrv: 55,
              sdnn: false),
          target)!;
      final sdnn = computeDailyScore(
          _seriesDays(
              target: target,
              priorCount: 10,
              priorHrv: 44,
              targetHrv: 55,
              sdnn: true),
          target)!;
      expect(sdnn.hrvScore, rmssd.hrvScore);
      expect(sdnn.dailyExact, rmssd.dailyExact);
      expect(sdnn.dailyScore, rmssd.dailyScore);
      expect(rmssd.hrvFromSdnn, isFalse);
      expect(sdnn.hrvFromSdnn, isTrue);
    });

    test('an SDNN-only day with fewer than 7 SDNN baseline days '
        'has NO HRV component (baseline minimum is series-local)',
        () {
      // 10 priors carry sleep + resting HR (so those components
      // are available), but only the last 6 carry SDNN — the HRV
      // baseline minimum applies to the SDNN series alone.
      final priors = _priorDates(target, 10);
      final days = _mapOf([
        for (var i = 0; i < priors.length; i++)
          DailyBiometrics(
            date: priors[i],
            sleepMinutes: 480,
            restingHrBpm: 60,
            hrvSdnnMs: i >= 4 ? 50 : null,
          ),
        const DailyBiometrics(
          date: target,
          sleepMinutes: 480,
          restingHrBpm: 60,
          hrvSdnnMs: 50,
        ),
      ]);
      final c = computeDailyScore(days, target)!;
      expect(c.hrvScore, isNull);
      expect(c.hrvMs, isNull);
      expect(c.hrvFromSdnn, isFalse);
      // The day still scores on the other components (the
      // null-component reweighting carries it).
      expect(c.sleepScore, isNotNull);
      expect(c.restingHrScore, isNotNull);
      expect(c.dailyScore, isNotNull);
    });

    test('null reweighting parity: an SDNN day with no baseline '
        'scores exactly like an RMSSD day with no baseline', () {
      Map<String, DailyBiometrics> noBaseline(bool sdnn) => _mapOf([
            for (final d in _priorDates(target, 10))
              DailyBiometrics(
                  date: d, sleepMinutes: 480, restingHrBpm: 60),
            DailyBiometrics(
              date: target,
              sleepMinutes: 480,
              restingHrBpm: 60,
              hrvRmssdMs: sdnn ? null : 55,
              hrvSdnnMs: sdnn ? 55 : null,
            ),
          ]);
      final android = computeDailyScore(noBaseline(false), target)!;
      final ios = computeDailyScore(noBaseline(true), target)!;
      expect(android.hrvScore, isNull);
      expect(ios.hrvScore, isNull);
      expect(ios.dailyExact, android.dailyExact);
    });
  });

  group('series never mixed', () {
    const target = '2026-11-21';

    test('mixed history: interleaved RMSSD/SDNN priors — each '
        'target scores against ONLY its own series baseline', () {
      // 10 RMSSD priors at 40 ms and 10 SDNN priors at 120 ms,
      // interleaved. A mixed baseline median would be 80 ms;
      // against it an at-own-baseline day would score far from
      // the 70 anchor — so 70 on both targets pins no mixing.
      final priors = <DailyBiometrics>[];
      final dates = _priorDates(target, 20);
      for (var i = 0; i < dates.length; i++) {
        final sdnnDay = i.isOdd;
        priors.add(DailyBiometrics(
          date: dates[i],
          sleepMinutes: 480,
          restingHrBpm: 60,
          hrvRmssdMs: sdnnDay ? null : 40,
          hrvSdnnMs: sdnnDay ? 120 : null,
        ));
      }
      final rmssdTarget = computeDailyScore(
          _mapOf([
            ...priors,
            const DailyBiometrics(
                date: target,
                sleepMinutes: 480,
                restingHrBpm: 60,
                hrvRmssdMs: 40),
          ]),
          target)!;
      expect(rmssdTarget.hrvBaselineMs, 40);
      expect(rmssdTarget.hrvScore, 70);
      expect(rmssdTarget.hrvFromSdnn, isFalse);

      final sdnnTarget = computeDailyScore(
          _mapOf([
            ...priors,
            const DailyBiometrics(
                date: target,
                sleepMinutes: 480,
                restingHrBpm: 60,
                hrvSdnnMs: 120),
          ]),
          target)!;
      expect(sdnnTarget.hrvBaselineMs, 120);
      expect(sdnnTarget.hrvScore, 70);
      expect(sdnnTarget.hrvFromSdnn, isTrue);
    });

    test('platform switch rebuilds the baseline: SDNN days after '
        'an RMSSD history stay HRV-less until 7 SDNN days exist',
        () {
      // 10 RMSSD days, then SDNN days accumulate one by one.
      final rows = <DailyBiometrics>[
        for (final d in _priorDates('2026-11-11', 10))
          DailyBiometrics(
              date: d, sleepMinutes: 480, restingHrBpm: 60, hrvRmssdMs: 40),
      ];
      var day = DateTime.parse('2026-11-11');
      // SDNN days 1..6: no SDNN baseline yet (0..5 prior SDNN
      // days) — the rich RMSSD history must NOT lend a baseline.
      for (var i = 0; i < 6; i++) {
        final date = _ds(day);
        rows.add(DailyBiometrics(
            date: date, sleepMinutes: 480, restingHrBpm: 60, hrvSdnnMs: 90));
        final c = computeDailyScore(_mapOf(rows), date)!;
        expect(c.hrvScore, isNull,
            reason: 'SDNN day ${i + 1} after switch must not score HRV');
        day = day.add(const Duration(days: 1));
      }
      // The 8th SDNN day is the first with 7 SDNN baseline days.
      rows.add(DailyBiometrics(
          date: _ds(day), sleepMinutes: 480, restingHrBpm: 60, hrvSdnnMs: 90));
      day = day.add(const Duration(days: 1));
      final eighth = _ds(day);
      rows.add(DailyBiometrics(
          date: eighth, sleepMinutes: 480, restingHrBpm: 60, hrvSdnnMs: 90));
      final c = computeDailyScore(_mapOf(rows), eighth)!;
      expect(c.hrvScore, 70);
      expect(c.hrvBaselineMs, 90);
      expect(c.hrvFromSdnn, isTrue);
    });

    test('a day carrying BOTH series scores from RMSSD (Android '
        'precedence — the RMSSD computation is unchanged)', () {
      final days = _seriesDays(
          target: '2026-11-20',
          priorCount: 10,
          priorHrv: 40,
          targetHrv: 40,
          sdnn: false);
      days['2026-11-20'] = const DailyBiometrics(
        date: '2026-11-20',
        sleepMinutes: 480,
        restingHrBpm: 60,
        hrvRmssdMs: 40,
        hrvSdnnMs: 999,
      );
      final c = computeDailyScore(days, '2026-11-20')!;
      expect(c.hrvMs, 40);
      expect(c.hrvScore, 70);
      expect(c.hrvFromSdnn, isFalse);
    });
  });

  group('engine persistence + labels', () {
    test('the engine persists an SDNN-sourced HRV component '
        '(write-once path, data-keyed gate)', () async {
      final store = _storeFor(<String, String>{});
      await store.warmFromDisk();
      await store.mergeRefresh([
        for (final d in _priorDates('2026-11-11', 10))
          DailyBiometrics(
              date: d, sleepMinutes: 480, restingHrBpm: 60, hrvSdnnMs: 50),
        const DailyBiometrics(
            date: '2026-11-11',
            sleepMinutes: 480,
            restingHrBpm: 60,
            hrvSdnnMs: 50),
      ]);
      final written = await DailyScoreEngine(store: store)
          .computeMissingScores(beforeDate: '2026-11-12');
      expect(written, greaterThan(0));
      final row = (await store.readAll())['2026-11-11']!;
      expect(row.scoreHrv, 70);
      expect(row.dailyScore, isNotNull);
      expect(scoreHrvCameFromSdnn(row), isTrue);
    });

    test('scoreHrvCameFromSdnn + contributedComponentNames label '
        'persisted rows truthfully', () {
      const sdnnRow = DailyBiometrics(
        date: '2026-11-20',
        hrvSdnnMs: 50,
        dailyScore: 70,
        scoreSleep: 70,
        scoreHrv: 70,
        scoreRestingHr: 70,
      );
      expect(scoreHrvCameFromSdnn(sdnnRow), isTrue);
      expect(contributedComponentNames(sdnnRow),
          ['Sleep', 'HRV (SDNN)', 'Resting heart rate']);

      const rmssdRow = DailyBiometrics(
        date: '2026-11-20',
        hrvRmssdMs: 40,
        dailyScore: 70,
        scoreSleep: 70,
        scoreHrv: 70,
        scoreRestingHr: 70,
      );
      expect(scoreHrvCameFromSdnn(rmssdRow), isFalse);
      expect(contributedComponentNames(rmssdRow),
          ['Sleep', 'HRV (RMSSD)', 'Resting heart rate']);

      // An SDNN day whose HRV component did NOT contribute is
      // not labeled SDNN-sourced.
      const unscoredHrv = DailyBiometrics(
        date: '2026-11-20',
        hrvSdnnMs: 50,
        dailyScore: 70,
        scoreSleep: 70,
        scoreRestingHr: 70,
      );
      expect(scoreHrvCameFromSdnn(unscoredHrv), isFalse);
      expect(contributedComponentNames(unscoredHrv),
          ['Sleep', 'Resting heart rate']);
    });

    testWidgets('an unscored SDNN-only day (SDNN data present, '
        'RMSSD absent, SDNN baseline < 7) renders the detail row '
        'name HRV (SDNN)', (tester) async {
      final store = _storeFor(<String, String>{});
      await store.warmFromDisk();
      await store.mergeRefresh([
        // 10 priors carry sleep + resting HR only, so the day
        // scores on those components; NO prior carries SDNN, so
        // the target's HRV component cannot count (baseline < 7).
        for (final d in _priorDates('2026-11-20', 10))
          DailyBiometrics(date: d, sleepMinutes: 480, restingHrBpm: 60),
        const DailyBiometrics(
            date: '2026-11-20',
            sleepMinutes: 480,
            restingHrBpm: 60,
            hrvSdnnMs: 50),
      ]);
      await DailyScoreEngine(store: store)
          .computeMissingScores(beforeDate: '2026-11-21');
      final row = (await store.readAll())['2026-11-20']!;
      expect(row.dailyScore, isNotNull);
      expect(row.scoreHrv, isNull);
      expect(row.hrvRmssdMs, isNull);
      expect(row.hrvSdnnMs, 50);
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreDayScreen(store: store, date: '2026-11-20'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('HRV (SDNN)'), findsOneWidget);
      expect(find.text('HRV (RMSSD)'), findsNothing);
    });
  });

  group('capture bookkeeping (chunk 7 partial change)', () {
    // An iOS capture whose SDNN read comes back PARTIAL must not
    // run the post-capture score compute (B-02 write-once
    // protection, now that SDNN feeds the score); a clean SDNN
    // read lets the same capture score the stored days.
    Future<HealthHistoryStore> runCapture({required bool partial}) async {
      final hc = _PartialSdnnHc(partial: partial);
      final store = _storeFor(<String, String>{});
      await store.warmFromDisk();
      await store.mergeRefresh([
        for (var i = 10; i <= 19; i++)
          DailyBiometrics(
            date: '2026-11-$i',
            sleepMinutes: 480,
            restingHrBpm: 60,
            hrvSdnnMs: 50,
          ),
      ]);
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => DateTime(2026, 11, 21, 12));
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      return store;
    }

    test('SDNN partial: stored days stay unscored after capture',
        () async {
      final store = await runCapture(partial: true);
      final row = (await store.readAll())['2026-11-19']!;
      expect(row.dailyScore, isNull);
    });

    test('SDNN clean: the same capture scores the stored days',
        () async {
      final store = await runCapture(partial: false);
      final row = (await store.readAll())['2026-11-19']!;
      expect(row.dailyScore, isNotNull);
      expect(row.scoreHrv, 70);
    });
  });
}

/// iOS capture fake whose SDNN outcome is partial or clean.
class _PartialSdnnHc extends HealthConnectService {
  _PartialSdnnHc({required this.partial})
      : super(store: MemorySecureStore(), isIOSOverride: true);

  final bool partial;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];

  @override
  Future<HcReadOutcome<List<HrvSdnnSample>>> readHrvSdnnSamplesWithOutcome(
      int days) async {
    return HcReadOutcome(
      value: [
        HrvSdnnSample(
            t: DateTime(2026, 11, 20, 3).millisecondsSinceEpoch, ms: 50.0),
      ],
      partialCode: partial ? 'HRV_SDNN_SAMPLES_PARTIAL' : null,
    );
  }
}
