import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// In-memory fake for the cache's storage functions, so no test touches
/// platform channels.
class _FakeStore {
  final Map<String, String> values = {};
  int writes = 0;

  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Mock weather backend: canned ipinfo + Open-Meteo payloads.
MockClient _mockWeatherClient() {
  return MockClient((request) async {
    final host = request.url.host;
    if (host == 'ipinfo.io') {
      return http.Response(
          '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
    }
    if (host == 'api.open-meteo.com') {
      return http.Response(
          '{"current":{"temperature_2m":60.0,"weather_code":2,"is_day":1}}',
          200);
    }
    return http.Response('not found', 404);
  });
}

/// Repository whose background load never resolves: the widget test then
/// observes exactly what the cache seeded on the first frame, with zero
/// async gap and no later overwrite.
class _StalledRepository extends HealthRepository {
  _StalledRepository() : super();

  @override
  Future<TodayVitals> loadTodayVitals({required bool connected}) =>
      Completer<TodayVitals>().future;

  @override
  Future<({int? current, int? best})> loadStreak() =>
      Completer<({int? current, int? best})>().future;
}

/// Repository that resolves with the given values after [delay].
class _DelayedRepository extends HealthRepository {
  final TodayVitals vitals;
  final int? currentStreak;
  final int? bestStreak;

  _DelayedRepository({
    required this.vitals,
    this.currentStreak,
    this.bestStreak,
  }) : super();

  @override
  Future<TodayVitals> loadTodayVitals({required bool connected}) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return vitals;
  }

  @override
  Future<({int? current, int? best})> loadStreak() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return (current: currentStreak, best: bestStreak);
  }
}

void main() {
  // Oct 26, 2026 perf package: the sync-pull and habits caches are
  // STATIC and session-keyed, and cases in this file reuse one session
  // token across fresh fake servers — reset between cases so one
  // case's cached pull/habits body cannot be served to the next case.
  setUp(TabsBackend.debugResetSharedCaches);
  late _FakeStore store;

  setUp(() {
    store = _FakeStore();
    HomeDataCache.instance.debugSetStore(
        read: store.read, write: store.write, delete: store.delete);
    HomeDataCache.instance.debugReset();
  });

  tearDown(() {
    HomeDataCache.instance.debugReset();
  });

  group('HomeDataCache', () {
    test('starts empty', () {
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isFalse);
      expect(s.streakLoaded, isFalse);
      expect(s.vitals, isNull);
      expect(s.currentStreak, isNull);
    });

    test('applyVitals stores, reports change once, detects differences',
        () {
      const v1 = TodayVitals(
          heartRate: 72,
          activeCalories: 450,
          sleepMinutes: 420,
          logCountToday: 3);
      expect(HomeDataCache.instance.applyVitals(v1), isTrue);
      // Identical re-apply: no change.
      expect(HomeDataCache.instance.applyVitals(v1), isFalse);
      const v2 = TodayVitals(
          heartRate: 73,
          activeCalories: 450,
          sleepMinutes: 420,
          logCountToday: 3);
      expect(HomeDataCache.instance.applyVitals(v2), isTrue);
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isTrue);
      expect(s.vitals!.heartRate, 73);
    });

    test('applyStreak stores nulls as loaded-empty', () {
      expect(HomeDataCache.instance.applyStreak(null, null), isTrue);
      expect(HomeDataCache.instance.applyStreak(null, null), isFalse);
      final s = HomeDataCache.instance.snapshot;
      expect(s.streakLoaded, isTrue);
      expect(s.currentStreak, isNull);
      expect(s.bestStreak, isNull);
    });

    test('absence of data is cached: all-null vitals mark loaded', () {
      // HC not connected: biometrics null, log count real.
      HomeDataCache.instance.applyVitals(const TodayVitals(logCountToday: 0));
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isTrue);
      expect(s.vitals!.heartRate, isNull);
      expect(s.vitals!.logCountToday, 0);
    });

    test('persist writes JSON; warmFromDisk restores it', () async {
      HomeDataCache.instance.applyVitals(const TodayVitals(
          heartRate: 72,
          activeCalories: 450,
          sleepMinutes: 420,
          logCountToday: 3));
      HomeDataCache.instance.applyStreak(12, 30);
      await HomeDataCache.instance.persist();
      expect(store.writes, 1);

      final raw = store.values[HomeDataCache.storageKey]!;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['vitals']['heartRate'], 72);
      expect(decoded['currentStreak'], 12);
      expect(decoded['bestStreak'], 30);

      HomeDataCache.instance.debugReset();
      await HomeDataCache.instance.warmFromDisk();
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isTrue);
      expect(s.vitals!.heartRate, 72);
      expect(s.vitals!.activeCalories, 450);
      expect(s.vitals!.sleepMinutes, 420);
      expect(s.vitals!.logCountToday, 3);
      expect(s.streakLoaded, isTrue);
      expect(s.currentStreak, 12);
      expect(s.bestStreak, 30);
    });

    test('persist with nothing loaded writes nothing', () async {
      await HomeDataCache.instance.persist();
      expect(store.writes, 0);
      expect(store.values, isEmpty);
    });

    test('warmFromDisk drops previous-day vitals, keeps streaks', () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      HomeDataCache.instance
          .applyVitals(const TodayVitals(heartRate: 72), now: yesterday);
      HomeDataCache.instance.applyStreak(12, 30, now: yesterday);
      await HomeDataCache.instance.persist();

      HomeDataCache.instance.debugReset();
      await HomeDataCache.instance.warmFromDisk();
      final s = HomeDataCache.instance.snapshot;
      // Vitals are date-bound: yesterday's numbers must not show as today's.
      expect(s.vitalsLoaded, isFalse);
      // Streaks are valid up to 7 days.
      expect(s.streakLoaded, isTrue);
      expect(s.currentStreak, 12);
    });

    test('warmFromDisk drops streaks older than 7 days', () async {
      final old = DateTime.now().subtract(const Duration(days: 8));
      HomeDataCache.instance.applyStreak(12, 30, now: old);
      await HomeDataCache.instance.persist();

      HomeDataCache.instance.debugReset();
      await HomeDataCache.instance.warmFromDisk();
      expect(HomeDataCache.instance.snapshot.streakLoaded, isFalse);
    });

    test('warmFromDisk with corrupt JSON starts empty, never throws',
        () async {
      store.values[HomeDataCache.storageKey] = 'not-json{{{';
      await HomeDataCache.instance.warmFromDisk();
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isFalse);
      expect(s.streakLoaded, isFalse);
    });

    test('warmFromDisk with wrong-typed JSON starts empty, never throws',
        () async {
      // Parses as JSON but the types are wrong — the casts must not
      // propagate (Vera advisory, round 16).
      store.values[HomeDataCache.storageKey] = jsonEncode({
        'fetchedAt': 12345,
        'vitalsLoaded': 'yes',
        'vitals': [1, 2, 3],
        'streakLoaded': true,
        'currentStreak': {'nested': 'object'},
      });
      await HomeDataCache.instance.warmFromDisk();
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isFalse);
      expect(s.streakLoaded, isFalse);
    });

    test('warmFromDisk with missing fetchedAt starts empty', () async {
      store.values[HomeDataCache.storageKey] =
          jsonEncode({'vitalsLoaded': true});
      await HomeDataCache.instance.warmFromDisk();
      expect(HomeDataCache.instance.snapshot.vitalsLoaded, isFalse);
    });

    test('warmFromDisk leaves already-loaded memory sections alone',
        () async {
      HomeDataCache.instance.applyStreak(99, 100);
      final old = DateTime.now().subtract(const Duration(days: 2));
      store.values[HomeDataCache.storageKey] = jsonEncode({
        'fetchedAt': old.toIso8601String(),
        'vitalsLoaded': false,
        'vitals': null,
        'streakLoaded': true,
        'currentStreak': 1,
        'bestStreak': 2,
      });
      await HomeDataCache.instance.warmFromDisk();
      expect(HomeDataCache.instance.snapshot.currentStreak, 99);
      expect(HomeDataCache.instance.snapshot.bestStreak, 100);
    });

    test('snapshot enforces the same-day rule on in-memory vitals', () {
      // Juno (round 16): a process alive past local midnight must not
      // seed yesterday's vitals into a remount.
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      HomeDataCache.instance
          .applyVitals(const TodayVitals(heartRate: 72), now: yesterday);
      HomeDataCache.instance.applyStreak(12, 30, now: yesterday);
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isFalse);
      expect(s.vitals, isNull);
      // Streaks are still within their 7-day window.
      expect(s.streakLoaded, isTrue);
      expect(s.currentStreak, 12);
    });

    test('clear wipes memory and disk', () async {
      HomeDataCache.instance.applyVitals(const TodayVitals(heartRate: 72));
      HomeDataCache.instance.applyStreak(12, 30);
      await HomeDataCache.instance.persist();
      expect(store.values, isNotEmpty);

      await HomeDataCache.instance.clear();
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isFalse);
      expect(s.streakLoaded, isFalse);
      expect(store.values.containsKey(HomeDataCache.storageKey), isFalse);
    });
  });

  group('HomeScreen cache seeding (stale-while-revalidate)', () {
    // The HC bridge channel is unmocked by default; an unhandled invoke
    // hangs instead of throwing, which would stall _loadHealthData's
    // isConnected() forever. Answer isAvailable=false so the background
    // load proceeds deterministically (HC not connected).
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(HealthConnectService.channelName),
        (call) async {
          if (call.method == 'isAvailable') return false;
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(HealthConnectService.channelName), null);
    });

    testWidgets('tab-switch remount renders cached numbers, zero async gap',
        (tester) async {
      HomeDataCache.instance.applyVitals(const TodayVitals(
          heartRate: 72,
          activeCalories: 450,
          sleepMinutes: 420,
          logCountToday: 3));
      HomeDataCache.instance.applyStreak(12, 30);

      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: WeatherApiClient(client: _mockWeatherClient()),
          healthRepository: _StalledRepository(),
        ),
      ));
      // First frame: cached numbers, no "--" flash for the seeded cells.
      // (Round 17b: sleep renders native "7h0m", not total minutes.)
      expect(find.text('72'), findsOneWidget);
      expect(find.text('450'), findsOneWidget);
      expect(find.text('7h0m'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);

      // Time passes with the background load stalled: values stay put,
      // no loading state ever appears.
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('72'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      // The Weekly Snapshot card below the vitals is NOT stalled: its
      // load completes empty promptly (HC unavailable) and, since the
      // Oct 26, 2026 founder spec (365a0ef), it legitimately shows its
      // own loading spinner while that load is in flight — HomeScreen
      // also remounts the card once as it settles, restarting the
      // load, so the completed load's frame lands one pump later.
      // Settle those frames, then the assertion below keeps its
      // original meaning: no spinner/shimmer for the CACHE-SEEDED
      // vitals and streak while their (stalled) load never resolves.
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Flush the staggered-entrance timers before teardown (round-14
      // lesson: a timed pump schedules delayed work at its end frame,
      // so follow with a second pump).
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    });

    testWidgets('cached absence renders "--" instantly, not a shimmer',
        (tester) async {
      // HC not connected on the last load: honestly empty, cached.
      HomeDataCache.instance.applyVitals(const TodayVitals(logCountToday: 0));
      HomeDataCache.instance.applyStreak(null, null);

      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: WeatherApiClient(client: _mockWeatherClient()),
          healthRepository: _StalledRepository(),
        ),
      ));
      // Biometrics show "--" from the loaded-empty cache; log count 0 is
      // real data.
      expect(find.text('--'), findsWidgets);
      expect(find.text('0'), findsOneWidget);
      // No spinner for the seeded cells. The Weekly Snapshot card's
      // own (founder-spec, Oct 26, 2026) loading spinner is separate:
      // its load completes empty promptly (HC unavailable), so settle
      // its frames first — after that, no spinner anywhere, exactly
      // as this case has always asserted.
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Flush the staggered-entrance timers before teardown (see above).
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    });

    testWidgets('background refresh swaps in new values silently',
        (tester) async {
      // Seed with yesterday's truth…
      HomeDataCache.instance.applyVitals(const TodayVitals(
          heartRate: 70,
          activeCalories: 400,
          sleepMinutes: 400,
          logCountToday: 2));
      HomeDataCache.instance.applyStreak(11, 30);

      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          weatherApi: WeatherApiClient(client: _mockWeatherClient()),
          // …then the refresh lands with new numbers.
          healthRepository: _DelayedRepository(
            vitals: const TodayVitals(
                heartRate: 75,
                activeCalories: 460,
                sleepMinutes: 430,
                logCountToday: 4),
            currentStreak: 12,
            bestStreak: 30,
          ),
        ),
      ));
      // First frame: the stale cache.
      expect(find.text('70'), findsOneWidget);

      // Refresh resolves (two sequential 100ms delays: vitals, then
      // streak): new values swap in (no count-up replay — the once-per-day
      // gate fails closed in tests, so they render instantly).
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('75'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);

      // Flush the staggered-entrance timers before teardown (see above).
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    });
  });
}
