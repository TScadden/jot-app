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
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

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

/// Fake store whose reads can be made to throw (C-02b): a transient
/// storage failure must be distinguishable from a missing/corrupt
/// blob. Writes/deletes behave like [_FakeStore].
class _FlakyStore extends _FakeStore {
  bool throwOnRead = false;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw StateError('storage read failed');
    return super.read(key);
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
  Future<({bool succeeded, int? current, int? best})> loadStreak() =>
      Completer<({bool succeeded, int? current, int? best})>().future;
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
  Future<({bool succeeded, int? current, int? best})> loadStreak() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return (succeeded: true, current: currentStreak, best: bestStreak);
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

    test(
        'C-02c: fresh vitals/log-count applies do not re-stamp an old '
        'streak as fresh', () {
      // The streak was fetched 8 days ago (past streakMaxAge); vitals
      // and the log count are refreshed NOW. The shared-stamp bug kept
      // the streak "fresh" forever on those unrelated re-stamps.
      final old = DateTime.now().subtract(const Duration(days: 8));
      HomeDataCache.instance.applyStreak(12, 30, now: old);
      final now = DateTime.now();
      HomeDataCache.instance
          .applyVitals(const TodayVitals(heartRate: 72), now: now);
      HomeDataCache.instance.applyLogCountToday(4, now: now);
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isTrue);
      expect(s.streakLoaded, isFalse,
          reason: 'an 8-day-old streak must not ride a fresh vitals '
              'stamp back inside streakMaxAge');
      expect(s.currentStreak, isNull);
      expect(s.bestStreak, isNull);
    });

    test(
        'C-02c: an old streak stays stale after persist + warm, even '
        'with fresh vitals in the same blob', () async {
      final old = DateTime.now().subtract(const Duration(days: 8));
      HomeDataCache.instance.applyStreak(12, 30, now: old);
      HomeDataCache.instance
          .applyVitals(const TodayVitals(heartRate: 72));
      HomeDataCache.instance.applyLogCountToday(4);
      await HomeDataCache.instance.persist();

      HomeDataCache.instance.debugReset();
      await HomeDataCache.instance.warmFromDisk();
      final s = HomeDataCache.instance.snapshot;
      expect(s.vitalsLoaded, isTrue);
      expect(s.streakLoaded, isFalse);
      expect(s.currentStreak, isNull);
    });

    test('C-02c: the persisted blob carries its own streakFetchedAt',
        () async {
      final t = DateTime.now().subtract(const Duration(days: 2));
      HomeDataCache.instance.applyStreak(9, 18, now: t);
      await HomeDataCache.instance.persist();
      final decoded = jsonDecode(store.values[HomeDataCache.storageKey]!)
          as Map<String, dynamic>;
      expect(decoded['streakFetchedAt'], t.toIso8601String());
    });

    test(
        'C-02 migration: a legacy blob without streakFetchedAt does '
        'not resurrect its streak as fresh', () async {
      // Pre-C-02 blobs carry only the shared fetchedAt, which any
      // vitals/log-count apply could re-stamp — it cannot prove when
      // the streak itself was fetched, so the streak section is
      // treated as stale (never adopted as fresh) and is rewritten
      // with its own stamp by the next successful streak pull.
      final now = DateTime.now();
      store.values[HomeDataCache.storageKey] = jsonEncode({
        'ownerEmail': null,
        'fetchedAt': now.toIso8601String(),
        'vitalsLoaded': false,
        'vitals': null,
        'streakLoaded': true,
        'currentStreak': 12,
        'bestStreak': 30,
        'countersLoaded': false,
        'counters': <dynamic>[],
        'countersFetchedAt': null,
      });
      await HomeDataCache.instance.warmFromDisk(now: now);
      final s = HomeDataCache.instance.snapshot;
      expect(s.streakLoaded, isFalse);
      expect(s.currentStreak, isNull);
      expect(s.bestStreak, isNull);
    });

    test(
        'C-02b: a throwing warm read gates persist — the on-disk blob '
        'survives a partial apply byte-identical, and the next warm '
        'does not delete it', () async {
      final cache = HomeDataCache.instance;
      const counter = EventCounterItem(
          id: 'c1', name: 'Trip', targetDate: 1893456000000);
      cache.applyVitals(const TodayVitals(heartRate: 70, logCountToday: 2),
          ownerEmail: 'owner@example.com');
      cache.applyStreak(7, 21, ownerEmail: 'owner@example.com');
      cache.applyCounters(const [counter],
          ownerEmail: 'owner@example.com');
      await cache.persist();
      final blob = store.values[HomeDataCache.storageKey]!;
      expect(blob, contains('"ownerEmail":"owner@example.com"'));

      // Cold start against a storage layer whose reads throw.
      final flaky = _FlakyStore();
      flaky.values[HomeDataCache.storageKey] = blob;
      flaky.throwOnRead = true;
      cache.debugSetStore(
          read: flaky.read, write: flaky.write, delete: flaky.delete);
      cache.debugReset();
      await cache.warmFromDisk(currentEmail: 'owner@example.com');

      // A partial apply + persist (the Quick Log / Home path) must
      // not overwrite the unread blob with the partial memory image.
      cache.applyVitals(const TodayVitals(heartRate: 99, logCountToday: 5));
      await cache.persist();
      expect(flaky.writes, 0,
          reason: 'persist must no-op until a warm has succeeded');
      expect(flaky.values[HomeDataCache.storageKey], blob,
          reason: 'counters and owner must survive on disk untouched');

      // Reads heal: the following warm adopts the original blob —
      // the owner matches, so nothing is deleted as foreign.
      flaky.throwOnRead = false;
      await cache.warmFromDisk(currentEmail: 'owner@example.com');
      expect(flaky.values.containsKey(HomeDataCache.storageKey), isTrue);
      final s = cache.snapshot;
      expect(s.ownerEmail, 'owner@example.com');
      expect(s.countersLoaded, isTrue);
      expect(s.counters.single.id, 'c1');
      expect(s.currentStreak, 7);
      expect(s.bestStreak, 21);
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
      // Phase 2 PR-2 re-point: the availability probe reads the
      // persisted-connection flag through secure storage BEFORE
      // the bridge check (the old getStatus path never touched
      // that channel); an unhandled storage invoke hangs like the
      // bridge one. Answer ONLY the probe's read (the granted-
      // permissions key, empty = no persisted connection); every
      // other storage call keeps the unhandled hang this file's
      // choreography was written against.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) {
          final args = call.arguments;
          if (call.method == 'read' &&
              args is Map &&
              args['key'] == 'hc_granted_permissions') {
            return Future<String?>.value(null);
          }
          return Completer<String?>().future;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(HealthConnectService.channelName), null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(
                  'plugins.it_nomads.com/flutter_secure_storage'),
              null);
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
