import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// V-2 correction (Vera MAJOR) — snapshot-first loads must never
/// stall on a wedged Health Connect read, and captures must not
/// stack.
///
/// - Every read inside [HealthHistorySync.captureFromHealthConnect]
///   is bounded by [HealthConnectService.readTimeout]; a timeout
///   degrades exactly like a failed read (empty result, a
///   `READ_TIMEOUT` diagnostics entry, the capture completes, and
///   screens score from store truth and render).
/// - [HealthHistorySync.capture] is single-flight: concurrent
///   non-forced calls share one run; a forced call arriving
///   mid-flight of a non-forced run chains its own forced run
///   behind it (never silently downgraded); a forced call during
///   a forced run joins it.
/// - Delta-2: the flight state is STATIC/shared, because
///   production defaults build a fresh sync per call (Home,
///   DailyScoreScreen, DailyScoreRefresher) while other paths
///   use the singleton — per-instance state was four flight
///   domains and the dedupe never engaged in production. Two
///   DISTINCT `withDeps` syncs on the same store must therefore
///   dedupe and chain exactly like one instance.

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

HealthHistoryStore _fakeStore(_FakeStore fake) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
  return store;
}

/// Every read returns instantly-empty except resting HR, which
/// NEVER completes — the wedged bridge read.
class _NeverHc extends HealthConnectService {
  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) =>
      Completer<List<({String date, int bpm})>>().future;

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(int days) async =>
      const [];
}

/// Resting-HR reads are gated on per-call completers the test
/// releases by hand; every call is counted.
class _GatedHc extends HealthConnectService {
  final List<Completer<List<({String date, int bpm})>>> gates = [];
  int restingHrCalls = 0;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) {
    restingHrCalls++;
    final gate = Completer<List<({String date, int bpm})>>();
    gates.add(gate);
    return gate.future;
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(int days) async =>
      const [];
}

/// Lets queued microtasks/async gaps run without advancing timers.
Future<void> _flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  // Delta-2 housekeeping: the flight state is now static/shared,
  // so a capture pended by one test must never leak into the
  // next — reset it around every test in this file.
  setUp(() {
    HealthHistorySync.debugResetFlight();
  });
  tearDown(() {
    HealthHistorySync.debugResetFlight();
  });

  group('single-flight capture', () {
    test('concurrent non-forced captures share ONE run', () async {
      final store = _fakeStore(_FakeStore());
      final hc = _GatedHc();
      final sync = HealthHistorySync.withDeps(hc: hc, store: store);

      final first = sync.capture();
      final second = sync.capture();
      await _flush();
      expect(hc.restingHrCalls, 1); // one run, not two

      hc.gates.single.complete(const []);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(hc.restingHrCalls, 1);
    });

    test(
        'a forced call arriving mid-flight of a non-forced run '
        'chains its own forced run behind it', () async {
      final store = _fakeStore(_FakeStore());
      final hc = _GatedHc();
      final sync = HealthHistorySync.withDeps(hc: hc, store: store);

      final first = sync.capture();
      await _flush();
      expect(hc.restingHrCalls, 1);

      final forced = sync.capture(force: true);
      await _flush();
      // Not downgraded, not parallel: the forced run has not
      // started while the first is in flight.
      expect(hc.restingHrCalls, 1);

      hc.gates[0].complete(const []);
      expect(await first, isTrue);
      await _flush();
      // The chained forced run now starts its own capture.
      expect(hc.restingHrCalls, 2);

      // A second forced call during the forced run joins it.
      final forcedJoin = sync.capture(force: true);
      await _flush();
      expect(hc.restingHrCalls, 2);

      hc.gates[1].complete(const []);
      expect(await forced, isTrue);
      expect(await forcedJoin, isTrue);
      expect(hc.restingHrCalls, 2);
    });

    test(
        'V-2 delta-2 wiring: two DISTINCT withDeps syncs on the '
        'SAME store share one flight — concurrent non-forced calls '
        'run exactly one HC read run, and a forced call on the '
        'second instance chains (not parallel, not downgraded)',
        () async {
      final store = _fakeStore(_FakeStore());
      final hc = _GatedHc();
      final syncA = HealthHistorySync.withDeps(hc: hc, store: store);
      final syncB = HealthHistorySync.withDeps(hc: hc, store: store);
      expect(identical(syncA, syncB), isFalse);

      // Concurrent non-forced calls ACROSS instances: one run.
      final first = syncA.capture();
      final second = syncB.capture();
      await _flush();
      expect(hc.restingHrCalls, 1); // one HC read run, not two

      hc.gates[0].complete(const []);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(hc.restingHrCalls, 1);
      await _flush();

      // A non-forced run started on one instance, then a forced
      // call on the OTHER instance: it chains behind the shared
      // flight — it does not run in parallel and is not
      // downgraded to the in-flight non-forced run.
      final nonForced = syncB.capture();
      await _flush();
      expect(hc.restingHrCalls, 2);

      final forced = syncA.capture(force: true);
      await _flush();
      expect(hc.restingHrCalls, 2);

      hc.gates[1].complete(const []);
      expect(await nonForced, isTrue);
      await _flush();
      // The chained forced run now starts its own capture.
      expect(hc.restingHrCalls, 3);

      // A forced call on the second instance during that forced
      // run joins it, cross-instance.
      final forcedJoin = syncB.capture(force: true);
      await _flush();
      expect(hc.restingHrCalls, 3);

      hc.gates[2].complete(const []);
      expect(await forced, isTrue);
      expect(await forcedJoin, isTrue);
      expect(hc.restingHrCalls, 3);
    });
  });

  group('bounded reads', () {
    test(
        'a never-completing read times out, records READ_TIMEOUT '
        'diagnostics, and the capture still completes', () async {
      final store = _fakeStore(_FakeStore());
      final sync = HealthHistorySync.withDeps(
        hc: _NeverHc(),
        store: store,
        readTimeoutOverride: const Duration(milliseconds: 50),
      );
      expect(await sync.capture(), isTrue);
      final diag = store.lastCaptureDiagnostics['restingHr'];
      expect(diag, isNotNull);
      expect(diag!.errorCode, 'READ_TIMEOUT');
    });
  });

  group('snapshot-first screens with a wedged read', () {
    /// 28 baseline days + today, all complete; today scored 82
    /// (sleep 100, HRV 70, resting HR 70) by a plain engine run.
    Future<HealthHistoryStore> seededStore(_FakeStore fake) async {
      final store = _fakeStore(fake);
      final now = DateTime.now();
      final today = _ds(DateTime(now.year, now.month, now.day));
      final anchor = DateTime.parse(today);
      await store.mergeRefresh([
        for (var i = 28; i >= 1; i--)
          DailyBiometrics(
            date: _ds(anchor.subtract(Duration(days: i))),
            sleepMinutes: 480,
            restingHrBpm: 60,
            hrvRmssdMs: 40,
          ),
        DailyBiometrics(
          date: today,
          sleepMinutes: 480,
          restingHrBpm: 60,
          hrvRmssdMs: 40,
        ),
      ]);
      await DailyScoreEngine(store: store).computeMissingScores();
      expect((await store.readAll())[today]!.dailyScore, 82);
      return store;
    }

    HealthHistorySync wedgedSync(HealthHistoryStore store) =>
        HealthHistorySync.withDeps(
          hc: _NeverHc(),
          store: store,
          readTimeoutOverride: const Duration(milliseconds: 100),
        );

    testWidgets(
        'Home renders the persisted score even though the snapshot '
        'read never completes', (tester) async {
      final store = await seededStore(_FakeStore());
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
          dailyScoreSnapshotCapture: wedgedSync(store).capture,
        ),
      ));
      // Advance past the 100 ms read bound: the wedged read times
      // out, the capture completes, and Home reads the persisted
      // score back from the store.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('82'), findsOneWidget);
    });

    testWidgets(
        'score history renders its rows even though the snapshot '
        'read never completes', (tester) async {
      final store = await seededStore(_FakeStore());
      await tester.pumpWidget(MaterialApp(
        home: DailyScoreScreen(
          store: store,
          snapshotCapture: wedgedSync(store).capture,
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Loaded (not the blank SizedBox.shrink): the history list
      // with its scored rows renders from store truth.
      expect(find.text('Last 14 scored days'), findsOneWidget);
      expect(find.text('82'), findsWidgets);
    });
  });
}
