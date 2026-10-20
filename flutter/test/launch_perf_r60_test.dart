import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/launch_trace.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

import 'test_helpers.dart';

/// Round 60 — launch performance audit evidence.
///
/// Method label (honest): these are widget/unit tests with FAKE
/// delayed futures (150ms / 200ms / 500ms per fake source) run on
/// the test host — NOT device timings. They prove ORDER and
/// RELATIVE duration (sequential sum vs parallel max, request
/// counts, fake-clock landing times), never absolute device
/// numbers. See ~/workspace/audit-r60/launch-waterfall.md.
///
/// All tokens are obviously fake fixtures (Vera rule).

const _email = 'founder@tabs.app';
const _oldAccess = 'fake-access-old';
const _oldRefresh = 'fake-refresh-old';

/// Health Connect fake whose every read takes [delay].
class _DelayedHc extends HealthConnectService {
  final Duration delay;
  final int calories;
  final int sleep;
  _DelayedHc({
    this.delay = const Duration(milliseconds: 150),
    this.calories = 300,
    this.sleep = 420,
  });

  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.connected;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    await Future<void>.delayed(delay);
    final now = DateTime.now();
    final noon = DateTime(now.year, now.month, now.day, 12);
    return [HrSample(timeMs: noon.millisecondsSinceEpoch, bpm: 72)];
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async {
    await Future<void>.delayed(delay);
    return calories;
  }

  @override
  Future<int?> readSleepMinutes(String dateStr) async {
    await Future<void>.delayed(delay);
    return sleep;
  }
}

/// Backend whose sync pull takes [pullDelay] and counts requests.
TabsBackend _delayedBackend({
  required void Function() onPull,
  Duration pullDelay = const Duration(milliseconds: 150),
}) {
  final store = FakeSessionStore()..token = 'fake-token';
  final client = MockClient((request) async {
    if (request.url.path == '/api/sync/pull') {
      onPull();
      await Future<void>.delayed(pullDelay);
      final now = DateTime.now();
      return http.Response(
        jsonEncode({
          'entries': [
            {'timestamp': now.millisecondsSinceEpoch},
          ],
          'categories': <dynamic>[],
          'profile': {'currentStreak': 12, 'bestStreak': 30},
        }),
        200,
      );
    }
    return http.Response('not found', 404);
  });
  return TabsBackend(client: client, sessionStore: store);
}

void main() {
  group('LaunchTrace', () {
    setUp(() => LaunchTrace.instance.debugReset());
    tearDown(() => LaunchTrace.instance.debugReset());

    test('records marks in order with non-decreasing elapsed times',
        () {
      final trace = LaunchTrace.instance;
      trace.mark(LaunchTrace.processStart);
      trace.mark(LaunchTrace.cachesWarmed);
      trace.mark(LaunchTrace.runAppCalled);
      trace.mark(LaunchTrace.firstFrame);
      expect(
          trace.order,
          equals([
            LaunchTrace.processStart,
            LaunchTrace.cachesWarmed,
            LaunchTrace.runAppCalled,
            LaunchTrace.firstFrame,
          ]));
      final times = [
        for (final name in trace.order) trace.elapsed(name)!,
      ];
      for (var i = 1; i < times.length; i++) {
        expect(times[i] >= times[i - 1], isTrue);
      }
    });

    test('first mark wins — a remount cannot rewrite the timeline',
        () {
      final trace = LaunchTrace.instance;
      trace.mark(LaunchTrace.homeSeededFromCache);
      final first = trace.elapsed(LaunchTrace.homeSeededFromCache);
      trace.mark(LaunchTrace.homeSeededFromCache);
      expect(trace.elapsed(LaunchTrace.homeSeededFromCache), first);
      expect(trace.order, hasLength(1));
    });
  });

  group('sync pull single-flight (Round 60)', () {
    test(
        'concurrent pull consumers across instances share ONE '
        'network request', () async {
      var pulls = 0;
      TabsBackend make() => _delayedBackend(
          onPull: () => pulls++,
          pullDelay: const Duration(milliseconds: 200));
      final a = make();
      final b = make();
      final c = make();
      final sw = Stopwatch()..start();
      final results = await Future.wait<Object?>([
        a.fetchSyncPull(),
        b.fetchSyncPull(),
        c.fetchSyncPull(),
        a.fetchStreak(),
        b.fetchLogEntries(),
      ]);
      sw.stop();
      // ignore: avoid_print
      print('R60 pull dedupe: elapsed=${sw.elapsedMilliseconds}ms '
          'pulls=$pulls (base: 5 pulls)');
      expect(pulls, 1,
          reason: 'five concurrent consumers, one wire request');
      // Every consumer got the shared body.
      expect((results[0] as Map<String, dynamic>)['profile'],
          containsPair('currentStreak', 12));
      expect((results[3] as ({int? current, int? best})).current, 12);
      expect(results[4] as List, hasLength(1));
    });

    test(
        'single-flight is scoped per session: two DIFFERENT tokens '
        'never share a request or a result', () async {
      // Regression pin for the unscoped-slot failure the round-21
      // feeling tests caught: a tokenless/default instance racing a
      // signed-in instance at Home mount must not swallow the
      // signed-in pull (or vice versa).
      var pulls = 0;
      TabsBackend backendFor(String? token, int streak) {
        final store = FakeSessionStore()..token = token;
        return TabsBackend(
          client: MockClient((request) async {
            pulls++;
            await Future<void>.delayed(
                const Duration(milliseconds: 100));
            return http.Response(
              jsonEncode({
                'entries': <dynamic>[],
                'profile': {'currentStreak': streak, 'bestStreak': 1},
              }),
              200,
            );
          }),
          sessionStore: store,
        );
      }

      final results = await Future.wait([
        backendFor('fake-token-a', 12).fetchStreak(),
        backendFor('fake-token-b', 99).fetchStreak(),
        backendFor(null, 55).fetchStreak(),
      ]);
      expect(pulls, 2,
          reason: 'the two tokened sessions fetch separately; the '
              'tokenless caller makes no request at all');
      expect(results[0].current, 12);
      expect(results[1].current, 99);
      // No token → no request is even attempted by that instance's
      // own path, and it must NOT receive another session's body.
      expect(results[2].current, isNull);
    });

    test(
        'regression (Juno): two tokens that COLLIDED under the old '
        'hash-only key still get separate pulls and separate bodies',
        () async {
      // Fixture found offline by brute force over fake tokens:
      // 'fake-token-45020' and 'fake-token-49835' are distinct
      // strings with the SAME String.hashCode (883558361).
      // Object.hash combines only its arguments' hashCodes (plus a
      // per-process seed shared by both calls), so this pair
      // collided under the old `Object.hash(_baseUrl, token)` int
      // key in every process — verified across repeated runs. With
      // the int key, the second backend below would have joined the
      // first's in-flight pull and been handed ITS sync-pull body
      // (health data): 1 wire request, streak 12 for both. The
      // record key compares the pair for equality, so the pulls
      // stay separate. First pins prove the fixture really is a
      // colliding pair in this process too.
      const tokenA = 'fake-token-45020';
      const tokenB = 'fake-token-49835';
      expect(tokenA, isNot(tokenB));
      expect(tokenA.hashCode, tokenB.hashCode);
      expect(Object.hash(TabsBackend.defaultBaseUrl, tokenA),
          Object.hash(TabsBackend.defaultBaseUrl, tokenB));

      var pulls = 0;
      TabsBackend backendFor(String token, int streak) {
        final store = FakeSessionStore()..token = token;
        return TabsBackend(
          client: MockClient((request) async {
            pulls++;
            await Future<void>.delayed(
                const Duration(milliseconds: 100));
            return http.Response(
              jsonEncode({
                'entries': <dynamic>[],
                'profile': {'currentStreak': streak, 'bestStreak': 1},
              }),
              200,
            );
          }),
          sessionStore: store,
        );
      }

      final results = await Future.wait([
        backendFor(tokenA, 12).fetchStreak(),
        backendFor(tokenB, 99).fetchStreak(),
      ]);
      expect(pulls, 2,
          reason: 'colliding hashes must NOT merge two sessions '
              'into one in-flight pull');
      expect(results[0].current, 12);
      expect(results[1].current, 99);
    });

    test(
        'the single-flight slot serves nothing stale: a consumer '
        'arriving AFTER completion fetches fresh', () async {
      var pulls = 0;
      final backend = _delayedBackend(onPull: () => pulls++);
      await backend.fetchStreak();
      expect(pulls, 1);
      await backend.fetchStreak();
      expect(pulls, 2,
          reason: 'direct readers keep their uncached semantics — '
              'only IN-FLIGHT calls are shared');
    });
  });

  group('parallel vitals load (Round 60)', () {
    test(
        'loadTodayVitals: parallel max, not sequential sum '
        '(150ms fakes)', () async {
      // Self-calibrating sequential baseline: the four sources the
      // load consumes, awaited one after another on the same fakes.
      final seqHc = _DelayedHc();
      final seqBackend = _delayedBackend(onPull: () {});
      final seqSw = Stopwatch()..start();
      await seqBackend.fetchLogEntries();
      await seqHc.readHeartRateSamples('2026-10-15');
      await seqHc.readActiveCalories('2026-10-15');
      await seqHc.readSleepMinutes('2026-10-15');
      seqSw.stop();

      var pulls = 0;
      final repo = HealthRepository(
        hc: _DelayedHc(),
        backend: _delayedBackend(onPull: () => pulls++),
      );
      final sw = Stopwatch()..start();
      final vitals = await repo.loadTodayVitals(connected: true);
      sw.stop();
      // ignore: avoid_print
      print('R60 vitals: parallel=${sw.elapsedMilliseconds}ms '
          'sequential-baseline=${seqSw.elapsedMilliseconds}ms '
          '(base measured 658ms on the same 150ms fakes)');
      expect(vitals.heartRate, 72);
      expect(vitals.activeCalories, 300);
      expect(vitals.sleepMinutes, 420);
      expect(vitals.logCountToday, 1);
      expect(pulls, 1);
      expect(sw.elapsedMilliseconds,
          lessThan(seqSw.elapsedMilliseconds * 0.75),
          reason: 'parallel load must land near the slowest single '
              'source (~150ms), not the sum (~600ms)');
    });

    // Round 60 fix pin (Vera blocker) — per-read error isolation:
    // a read that THROWS (not a null failure) must degrade to its
    // own empty value only. With a single shared try/catch around
    // the Future.wait, the sleep throw landed before any assignment
    // and HR/calories were lost too; the sequential base kept each
    // value as it landed.
    test(
        'one THROWING read (sleep) does not poison the others: '
        'HR and calories still land, sleep is null', () async {
      final repo = HealthRepository(
        hc: _ThrowingSleepHc(),
        backend: _delayedBackend(
            onPull: () {},
            pullDelay: const Duration(milliseconds: 10)),
      );
      final vitals = await repo.loadTodayVitals(connected: true);
      expect(vitals.heartRate, 72);
      expect(vitals.activeCalories, 300);
      expect(vitals.sleepMinutes, isNull);
      expect(vitals.logCountToday, 1);
    });

    test('biometric 0 in the parallel path is a failed read → null',
        () async {
      final repo = HealthRepository(
        hc: _DelayedHc(
            delay: const Duration(milliseconds: 10),
            calories: 0,
            sleep: 0),
        backend: _delayedBackend(
            onPull: () {},
            pullDelay: const Duration(milliseconds: 10)),
      );
      final vitals = await repo.loadTodayVitals(connected: true);
      expect(vitals.activeCalories, isNull);
      expect(vitals.sleepMinutes, isNull);
      expect(vitals.heartRate, 72);
    });
  });

  group('session validation taxonomy at launch (Round 60)', () {
    setUp(() => TabsBackend.onSessionExpired = null);
    tearDown(() => TabsBackend.onSessionExpired = null);

    FakeSessionStore seeded() => FakeSessionStore()
      ..token = _oldAccess
      ..refreshToken = _oldRefresh
      ..email = _email;

    test('simulated timeout on the authed call ≠ sign-out', () async {
      final store = seeded();
      var expired = 0;
      TabsBackend.onSessionExpired = () => expired++;
      final backend = TabsBackend(
        client: MockClient(
            (_) async => throw TimeoutException('fake timeout')),
        sessionStore: store,
      );
      final streak = await backend.fetchStreak();
      expect(streak.current, isNull); // honest failure result
      expect(store.token, _oldAccess);
      expect(store.refreshToken, _oldRefresh);
      expect(store.email, _email);
      expect(expired, 0);
    });

    test('simulated timeout DURING refresh ≠ sign-out', () async {
      final store = seeded();
      var expired = 0;
      TabsBackend.onSessionExpired = () => expired++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            throw TimeoutException('fake refresh timeout');
          }
          return http.Response('{"error":"expired"}', 401);
        }),
        sessionStore: store,
      );
      final streak = await backend.fetchStreak();
      expect(streak.current, isNull);
      expect(store.token, _oldAccess);
      expect(store.refreshToken, _oldRefresh);
      expect(store.email, _email);
      expect(expired, 0);
    });

    test('simulated DNS/transport failure during refresh ≠ sign-out',
        () async {
      final store = seeded();
      var expired = 0;
      TabsBackend.onSessionExpired = () => expired++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            throw const SocketException('fake DNS failure');
          }
          return http.Response('{"error":"expired"}', 401);
        }),
        sessionStore: store,
      );
      final streak = await backend.fetchStreak();
      expect(streak.current, isNull);
      expect(store.token, _oldAccess);
      expect(store.refreshToken, _oldRefresh);
      expect(store.email, _email);
      expect(expired, 0);
    });

    test('simulated 5xx during refresh ≠ sign-out', () async {
      final store = seeded();
      var expired = 0;
      TabsBackend.onSessionExpired = () => expired++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            return http.Response('server boom', 500);
          }
          return http.Response('{"error":"expired"}', 401);
        }),
        sessionStore: store,
      );
      final streak = await backend.fetchStreak();
      expect(streak.current, isNull);
      expect(store.token, _oldAccess);
      expect(store.refreshToken, _oldRefresh);
      expect(store.email, _email);
      expect(expired, 0);
    });

    test('simulated definitive 401 refresh rejection = sign-out',
        () async {
      final store = seeded();
      var expired = 0;
      TabsBackend.onSessionExpired = () => expired++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            return http.Response(
                '{"error":"Refresh token expired"}', 401);
          }
          return http.Response('{"error":"expired"}', 401);
        }),
        sessionStore: store,
      );
      final streak = await backend.fetchStreak();
      expect(streak.current, isNull);
      expect(store.token, isNull);
      expect(store.refreshToken, isNull);
      expect(store.email, isNull);
      expect(expired, 1);
    });
  });

  group('snapshot-first paint + fresh-data landing (Round 60)', () {
    setUp(() {
      HomeDataCache.instance.debugReset();
      LaunchTrace.instance.debugReset();
    });
    tearDown(() {
      HomeDataCache.instance.debugReset();
      LaunchTrace.instance.debugReset();
    });

    testWidgets(
        'Home paints from the account-bound cache while every '
        'network future and the HC bridge NEVER complete',
        (tester) async {
      HomeDataCache.instance.applyVitals(
        const TodayVitals(
            heartRate: 72,
            activeCalories: 300,
            sleepMinutes: 420,
            logCountToday: 3),
        ownerEmail: _email,
      );
      HomeDataCache.instance.applyStreak(12, 30);

      final stalled =
          MockClient((_) => Completer<http.Response>().future);
      final backend = TabsBackend(
          client: stalled, sessionStore: FakeSessionStore()..token = 't');
      final repo = HealthRepository(hc: _StalledHc(), backend: backend);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: HomeScreen(
            email: _email,
            weatherApi: WeatherApiClient(client: stalled),
            healthRepository: repo,
            tabsBackend: backend,
          ),
        ),
      ));
      await tester.pump();

      // Painted from cache on the first frame — no network landed.
      expect(find.text('72'), findsOneWidget);
      expect(find.text('300'), findsOneWidget);
      expect(find.text('7h0m'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      // Trace: seeded-from-cache fired; fresh data has NOT.
      expect(LaunchTrace.instance.has(LaunchTrace.homeSeededFromCache),
          isTrue);
      expect(LaunchTrace.instance.has(LaunchTrace.homeFreshData),
          isFalse);
      // Flush the 20s HTTP-timeout timers the stalled calls armed.
      await tester.pump(const Duration(seconds: 21));
      await tester.pump();
      // V-2 drain (correction round): Home's Daily Score snapshot
      // capture bounds every Health Connect read at 30 s
      // (HealthConnectService.readTimeout); the bridge never
      // completes here by design, so each read's bound must
      // elapse before the fake-async teardown accepts the test.
      // The paint assertions above are already final — the score
      // load was never part of what this test measures.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 30));
      }
    });

    testWidgets(
        'fresh data lands at ~1× pull latency, not ~2× '
        '(500ms fake pull, fake clock)', (tester) async {
      var pulls = 0;
      final backend = _delayedBackend(
          onPull: () => pulls++,
          pullDelay: const Duration(milliseconds: 500));
      final repo = HealthRepository(hc: _InstantHc(), backend: backend);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: HomeScreen(
            email: _email,
            weatherApi: WeatherApiClient(
                client: MockClient(
                    (_) async => http.Response('not found', 404))),
            healthRepository: repo,
            tabsBackend: backend,
          ),
        ),
      ));
      await tester.pump();
      // Just past ONE pull latency: at base the streak's second,
      // sequential pull had not even started landing (values
      // appeared at ~1150ms); now vitals + streak share the single
      // in-flight pull and land together.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      // ignore: avoid_print
      print('R60 landing: at 600ms fake time pulls=$pulls '
          '(base: 4 pulls, values at ~1150ms)');
      expect(find.text('72'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(pulls, 1,
          reason: 'one Home mount = one sync pull on the wire');
      expect(LaunchTrace.instance.has(LaunchTrace.homeFreshData),
          isTrue);
      // V-2 drain (correction round): see the sibling test above
      // — the snapshot capture's per-read 30 s bounds (bridge
      // channel unmocked here) must elapse before teardown. The
      // landing assertions above are already final.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 30));
      }
    });
  });
}

/// Health Connect fake whose sleep read THROWS (a non-null
/// failure — e.g. a bridge type/parse error) while HR and calories
/// succeed. Pins the per-read error isolation in loadTodayVitals.
class _ThrowingSleepHc extends HealthConnectService {
  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.connected;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    final now = DateTime.now();
    final noon = DateTime(now.year, now.month, now.day, 12);
    return [HrSample(timeMs: noon.millisecondsSinceEpoch, bpm: 72)];
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async => 300;

  @override
  Future<int?> readSleepMinutes(String dateStr) async =>
      throw StateError('fake bridge parse failure');
}

class _StalledHc extends HealthConnectService {
  @override
  Future<HealthConnectStatus> getStatus() =>
      Completer<HealthConnectStatus>().future;
}

class _InstantHc extends HealthConnectService {
  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.connected;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    final now = DateTime.now();
    final noon = DateTime(now.year, now.month, now.day, 12);
    return [HrSample(timeMs: noon.millisecondsSinceEpoch, bpm: 72)];
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async => 300;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => 420;
}
