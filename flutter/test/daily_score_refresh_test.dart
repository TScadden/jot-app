import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_refresh.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// Daily Score refresh (founder direction, Oct 20, 2026) — the
/// user-initiated exception to write-once scoring:
///
/// - [HealthHistoryStore.replaceScore] is the ONLY overwrite path;
///   [HealthHistoryStore.persistScore] still refuses overwrites,
///   and the engine never rewrites a scored day.
/// - [DailyScoreRefresher] forces a capture (the button is the
///   only forcer; automatic captures keep the 6h throttle),
///   re-scores the viewed day ONLY, leaves the score untouched on
///   capture failure or a null recomputation, and carries any
///   newly recorded per-metric read failures in its outcome.
/// - The day detail shows the refresh control on scored days
///   only, disables it in flight, and re-renders from the
///   persisted record after a refresh; the history list and the
///   Home face pick the refreshed number up on return through
///   their existing reload paths.

/// In-memory fake for the store's storage functions (same shape
/// as daily_score_r70_test.dart).
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

const _target = '2026-10-16';

/// Baseline history (28 days: resting HR 60, HRV 40) + the target
/// day at resting HR 54 / HRV 32, scored by the engine:
/// resting HR −10% → 100, HRV −20% → 35, daily
/// (35·35 + 25·100) / 60 = 62. When a capture later lands HRV 50
/// for the target (+25% → 100), the refreshed daily score is 100.
Future<HealthHistoryStore> _seededStore(_FakeStore fake) async {
  final store = _fakeStore(fake);
  await store.mergeRefresh([
    for (final d in _priorDates(_target, 28))
      DailyBiometrics(date: d, restingHrBpm: 60, hrvRmssdMs: 40),
    const DailyBiometrics(date: _target, restingHrBpm: 54, hrvRmssdMs: 32),
  ]);
  await DailyScoreEngine(store: store).computeMissingScores();
  final row = (await store.readAll())[_target]!;
  assert(row.dailyScore == 62 &&
      row.scoreHrv == 35 &&
      row.scoreRestingHr == 100);
  return store;
}

/// A capture fake that lands [hrv] for the target day in the store
/// (what a real capture's merge would do with late-arriving data)
/// and returns true.
ScoreCapture _landingCapture(HealthHistoryStore store, {double hrv = 50}) {
  return ({bool force = false}) async {
    await store.mergeRefresh([
      DailyBiometrics(date: _target, hrvRmssdMs: hrv),
    ]);
    return true;
  };
}

void main() {
  group('store: replaceScore (the one overwrite path)', () {
    late _FakeStore fake;
    late HealthHistoryStore store;

    setUp(() {
      fake = _FakeStore();
      store = _fakeStore(fake);
    });

    test('replaces all four score fields, nulls included', () async {
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ]);
      await store.persistScore('2026-10-01',
          dailyScore: 50, scoreSleep: 60, scoreHrv: 40);
      final ok = await store.replaceScore('2026-10-01',
          dailyScore: 77, scoreRestingHr: 77);
      expect(ok, isTrue);
      final row = (await store.readAll())['2026-10-01']!;
      expect(row.dailyScore, 77);
      expect(row.scoreSleep, isNull); // replaced exactly, not merged
      expect(row.scoreHrv, isNull);
      expect(row.scoreRestingHr, 77);
      expect(row.restingHrBpm, 60); // biometrics untouched
      // And it persists: a cold store over the same disk sees it.
      final cold = _fakeStore(fake);
      expect((await cold.readAll())['2026-10-01']!.dailyScore, 77);
    });

    test('missing day: returns false and writes nothing', () async {
      expect(await store.replaceScore('2026-10-01', dailyScore: 50),
          isFalse);
      expect(await store.readAll(), isEmpty);
      expect(fake.values.containsKey(HealthHistoryStore.storageKey),
          isFalse);
    });

    test('write-once regression: persistScore still refuses overwrites',
        () async {
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-01', restingHrBpm: 60),
      ]);
      expect(await store.persistScore('2026-10-01', dailyScore: 50), isTrue);
      expect(await store.persistScore('2026-10-01', dailyScore: 99),
          isFalse);
      expect((await store.readAll())['2026-10-01']!.dailyScore, 50);
      // Even after a user-initiated replace, the automatic path
      // stays write-once.
      expect(await store.replaceScore('2026-10-01', dailyScore: 99),
          isTrue);
      expect(await store.persistScore('2026-10-01', dailyScore: 1),
          isFalse);
      expect((await store.readAll())['2026-10-01']!.dailyScore, 99);
    });
  });

  group('refresher: orchestration semantics', () {
    test(
        'new HRV data landing in the store changes the components '
        'and the number; the capture is forced', () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final forces = <bool>[];
      final landing = _landingCapture(store);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) {
          forces.add(force);
          return landing(force: force);
        },
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.computation!.dailyScore, 100);
      expect(outcome.newFailureCodes, isEmpty);
      expect(forces, [true]); // the button forces; nothing else may
      final row = (await store.readAll())[_target]!;
      expect(row.dailyScore, 100);
      expect(row.scoreHrv, 100); // was 35
      expect(row.scoreRestingHr, 100);
      expect(row.scoreSleep, isNull);
    });

    test('no new data: identical score, byte-identical persisted record',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final beforeRow = (await store.readAll())[_target]!;
      final beforeBlob = fake.values[HealthHistoryStore.storageKey];
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async => true,
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.computation!.dailyScore, 62);
      expect((await store.readAll())[_target], beforeRow);
      expect(fake.values[HealthHistoryStore.storageKey], beforeBlob);
    });

    test('failed capture (returns false): prior score untouched',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final beforeRow = (await store.readAll())[_target]!;
      final beforeBlob = fake.values[HealthHistoryStore.storageKey];
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async => false,
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.captureFailed);
      expect(outcome.computation, isNull);
      expect((await store.readAll())[_target], beforeRow);
      expect(fake.values[HealthHistoryStore.storageKey], beforeBlob);
    });

    test('throwing capture: reported as captureFailed, never thrown',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async =>
            throw StateError('boom'),
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.captureFailed);
      expect((await store.readAll())[_target]!.dailyScore, 62);
    });

    test('refreshing a past day changes no other day\'s stored score',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final allBefore = await store.readAll();
      final otherBefore = allBefore['2026-10-15']!;
      expect(otherBefore.dailyScore, 70); // baseline day, scored 70
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: _landingCapture(store),
      );
      await refresher.refresh(_target);
      final allAfter = await store.readAll();
      expect(allAfter[_target]!.dailyScore, 100);
      // Every other day's full record is untouched.
      for (final date in allBefore.keys) {
        if (date == _target) continue;
        expect(allAfter[date], allBefore[date], reason: date);
      }
      expect(allAfter['2026-10-15'], otherBefore);
    });

    test(
        'new diagnostics failures ride the outcome while the '
        'rescore still proceeds from store truth', () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final landing = _landingCapture(store);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async {
          await store.recordCaptureDiagnostics(
            failures: const {'sleep': 'SLEEP_HISTORY_READ_FAILED'},
            succeeded: const {},
            atMs: 999,
          );
          return landing(force: force);
        },
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.computation!.dailyScore, 100); // HRV still landed
      expect(outcome.newFailureCodes,
          {'sleep': 'SLEEP_HISTORY_READ_FAILED'});
    });

    test('a pre-existing diagnostics failure is not re-reported',
        () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      await store.recordCaptureDiagnostics(
        failures: const {'hrv': 'HRV_SAMPLES_READ_FAILED'},
        succeeded: const {},
        atMs: 123,
        hrvSampleCount: 0,
        hrvDayCount: 0,
      );
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async => true,
      );
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(outcome.newFailureCodes, isEmpty);
    });

    test(
        'null recomputation (no baselines): no-change, existing '
        'score left untouched', () async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 60),
      ]);
      await store.persistScore('2026-10-16', dailyScore: 42);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async => true,
      );
      final outcome = await refresher.refresh('2026-10-16');
      expect(outcome.status, DailyScoreRefreshStatus.noChange);
      expect((await store.readAll())['2026-10-16']!.dailyScore, 42);
      // A day not in the store at all: also a plain no-change.
      final missing = await refresher.refresh('2026-01-01');
      expect(missing.status, DailyScoreRefreshStatus.noChange);
      expect((await store.readAll()).containsKey('2026-01-01'), isFalse);
    });

    test(
        'automatic capture stays throttled; the refresher\'s forced '
        'capture runs (real sync wiring)', () async {
      final fake = _FakeStore();
      final store = await _seededStore(fake);
      final now = DateTime(2026, 10, 20, 12);
      await store.markCaptured(now.millisecondsSinceEpoch);
      final hc = _EmptyHc();
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => now);
      // Automatic (unforced) capture within the 6h window: skipped,
      // no reads at all.
      expect(await sync.capture(), isFalse);
      expect(hc.calls, 0);
      // The refresher, wired to the same sync, forces its capture.
      final refresher = DailyScoreRefresher(store: store, sync: sync);
      final outcome = await refresher.refresh(_target);
      expect(outcome.status, DailyScoreRefreshStatus.refreshed);
      expect(hc.calls, greaterThan(0));
      expect((await store.readAll())[_target]!.dailyScore, 62);
    });
  });

  group('widgets: day detail refresh control', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required HealthHistoryStore store,
      required String date,
      DailyScoreRefresher? refresher,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreDayScreen(
            store: store, date: date, refresher: refresher),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('scored day: control exists with a ≥48dp tap target',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      await pumpDetail(tester, store: store, date: _target);
      final control = find.byKey(const ValueKey('daily-score-refresh'));
      expect(control, findsOneWidget);
      expect(find.byTooltip('Refresh score'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      final size = tester.getSize(control);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
    });

    testWidgets('tap refresh: the number and components re-render '
        'from the persisted record', (tester) async {
      final store = await _seededStore(_FakeStore());
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: _landingCapture(store),
      );
      await pumpDetail(tester,
          store: store, date: _target, refresher: refresher);
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      expect(find.text('50.0 ms · your baseline 40 ms'), findsOneWidget);
      expect((await store.readAll())[_target]!.dailyScore, 100);
    });

    testWidgets('in flight: control disables, shows progress, and '
        'double-taps are ignored', (tester) async {
      final store = await _seededStore(_FakeStore());
      final completer = Completer<bool>();
      var captureCalls = 0;
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) {
          captureCalls++;
          return completer.future;
        },
      );
      await pumpDetail(tester,
          store: store, date: _target, refresher: refresher);
      final control = find.byKey(const ValueKey('daily-score-refresh'));
      await tester.tap(control);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final button = tester.widget<IconButton>(control);
      expect(button.onPressed, isNull);
      // A second tap while in flight does nothing.
      await tester.tap(control, warnIfMissed: false);
      await tester.pump();
      expect(captureCalls, 1);
      completer.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(captureCalls, 1);
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
    });

    testWidgets('no score stored: no refresh control', (tester) async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      await store.mergeRefresh([
        const DailyBiometrics(date: '2026-10-16', restingHrBpm: 60),
      ]);
      await pumpDetail(tester, store: store, date: '2026-10-16');
      expect(find.text('No score stored for this day.'), findsOneWidget);
      expect(find.byKey(const ValueKey('daily-score-refresh')),
          findsNothing);
      expect(find.byIcon(Icons.refresh), findsNothing);
    });

    testWidgets('capture failure: error shown with its code, '
        'displayed score untouched', (tester) async {
      final store = await _seededStore(_FakeStore());
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async => false,
      );
      await pumpDetail(tester,
          store: store, date: _target, refresher: refresher);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.textContaining('[CAPTURE_FAILED]'), findsWidgets);
      expect(
          find.text('Refresh failed. This score was not changed. '
              '[CAPTURE_FAILED]'),
          findsOneWidget);
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
      expect((await store.readAll())[_target]!.dailyScore, 62);
      // Flush the SnackBar's display timer before the test ends.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
    });

    testWidgets('diagnostics failures from the capture are shown '
        'plainly alongside the updated score', (tester) async {
      final store = await _seededStore(_FakeStore());
      final landing = _landingCapture(store);
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: ({bool force = false}) async {
          await store.recordCaptureDiagnostics(
            failures: const {'sleep': 'SLEEP_HISTORY_READ_FAILED'},
            succeeded: const {},
            atMs: 999,
          );
          return landing(force: force);
        },
      );
      await pumpDetail(tester,
          store: store, date: _target, refresher: refresher);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      expect(
          find.text('Some data could not be refreshed: Sleep '
              '[SLEEP_HISTORY_READ_FAILED]. This score was updated '
              'from the data that is stored.'),
          findsOneWidget);
    });
  });

  group('widgets: history + Home pick up a refreshed score', () {
    testWidgets('history list reloads on return from the day detail',
        (tester) async {
      final store = await _seededStore(_FakeStore());
      final refresher = DailyScoreRefresher.withCapture(
        store: store,
        capture: _landingCapture(store),
      );
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(store: store, refresher: refresher),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Target row first (newest scored), showing 62 before.
      expect(find.text('Fri, Oct 16'), findsOneWidget);
      expect(find.text('62'), findsWidgets);
      await tester.tap(find.text('Fri, Oct 16'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Daily Score: 62 · Good'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('daily-score-refresh')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('Daily Score: 100 · Great'), findsOneWidget);
      // Back to the history: the refreshed number is already there.
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('100'), findsWidgets);
      expect(find.text('62'), findsNothing);
    });

    testWidgets('refreshing today: the Home face shows the new '
        'number after the score screen pops', (tester) async {
      final fake = _FakeStore();
      final store = _fakeStore(fake);
      final today = DateTime.now();
      final todayStr = _ds(DateTime(today.year, today.month, today.day));
      await store.mergeRefresh([
        for (final d in _priorDates(todayStr, 28))
          DailyBiometrics(date: d, restingHrBpm: 60, hrvRmssdMs: 40),
        DailyBiometrics(date: todayStr, restingHrBpm: 54, hrvRmssdMs: 32),
      ]);
      // Today is scored by the post-capture engine run (TODAY
      // RULE), simulated here with no cutoff.
      await DailyScoreEngine(store: store).computeMissingScores();
      expect((await store.readAll())[todayStr]!.dailyScore, 62);
      final mockWeather = MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
              200);
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
      expect(find.text('62'), findsOneWidget);

      // A refresh of today persists a new score (the exact write
      // the refresher performs), then the user opens the score
      // screen and returns: Home's existing post-pop reload
      // (_openDailyScore → _loadDailyScore) must surface it.
      await store.replaceScore(todayStr,
          dailyScore: 100, scoreHrv: 100, scoreRestingHr: 100);
      await tester.tap(find.byType(DailyScoreCircle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(DailyScoreScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(DailyScoreCircle), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
      expect(find.text('Great'), findsOneWidget);
    });
  });
}

/// Fake HC source whose every window is empty; counts its reads
/// so the throttle test can prove an unforced capture read
/// nothing (mirrors hrv_grant_visibility_test.dart's fake).
class _EmptyHc extends HealthConnectService {
  int calls = 0;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async {
    calls++;
    return const [];
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
      int days) async {
    calls++;
    return const [];
  }

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    calls++;
    return const [];
  }

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
      int days) async {
    calls++;
    return const [];
  }

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async {
    calls++;
    return const [];
  }
}
