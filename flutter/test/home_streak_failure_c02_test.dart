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

import 'test_helpers.dart';

/// C-02a — a FAILED streak pull must be distinguishable from a
/// confirmed-empty streak, end to end: the repository reports the
/// failure, and Home's load then leaves the previously cached streak
/// standing (memory, disk, and the rendered pills) instead of
/// overwriting it with nulls. Verdict: verdicts/v-outbox.md, C-02(a).

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

MockClient _mockWeatherClient() {
  return MockClient((request) async {
    final host = request.url.host;
    if (host == 'ipinfo.io') {
      return http.Response(
        '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
        200,
      );
    }
    if (host == 'api.open-meteo.com') {
      return http.Response(
        '{"current":{"temperature_2m":60.0,"weather_code":2,"is_day":1}}',
        200,
      );
    }
    return http.Response('not found', 404);
  });
}

/// Repository whose streak pull FAILED (transport/backend failure —
/// not a confirmed-empty record): vitals resolve normally, the
/// streak reports `succeeded: false` with null counters, exactly
/// like `loadStreakRecord` already does for the engine settle.
class _FailedStreakRepository extends HealthRepository {
  _FailedStreakRepository() : super();

  @override
  Future<TodayVitals> loadTodayVitals({required bool connected}) async =>
      const TodayVitals(
        heartRate: 75,
        activeCalories: 460,
        sleepMinutes: 430,
        logCountToday: 4,
      );

  @override
  Future<({bool succeeded, int? current, int? best})> loadStreak() async =>
      (succeeded: false, current: null, best: null);

  @override
  Future<({bool succeeded, int? current, int? best, String? stateJson})>
  loadStreakRecord() async =>
      (succeeded: false, current: null, best: null, stateJson: null);
}

HealthRepository _repoWith(MockClient client, {String? token = 'tok'}) {
  final store = FakeSessionStore()..token = token;
  return HealthRepository(
    backend: TabsBackend(client: client, sessionStore: store),
  );
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);
  late _FakeStore store;

  setUp(() {
    store = _FakeStore();
    HomeDataCache.instance.debugSetStore(
      read: store.read,
      write: store.write,
      delete: store.delete,
    );
    HomeDataCache.instance.debugReset();
  });

  tearDown(() {
    HomeDataCache.instance.debugReset();
  });

  group('C-02a loadStreak success bit', () {
    test('transport failure → succeeded: false, nulls', () async {
      final repo = _repoWith(
        MockClient((_) async => throw http.ClientException('down')),
      );
      final streak = await repo.loadStreak();
      expect(streak.succeeded, isFalse);
      expect(streak.current, isNull);
      expect(streak.best, isNull);
    });

    test('successful pull → succeeded: true with the counters', () async {
      final repo = _repoWith(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'entries': [],
              'profile': {'currentStreak': 12, 'bestStreak': 30},
            }),
            200,
          ),
        ),
      );
      final streak = await repo.loadStreak();
      expect(streak.succeeded, isTrue);
      expect(streak.current, 12);
      expect(streak.best, 30);
    });

    test('successful pull with an empty profile → succeeded: true '
        '(confirmed-empty, not a failure)', () async {
      final repo = _repoWith(
        MockClient(
          (_) async =>
              http.Response(jsonEncode({'entries': [], 'profile': {}}), 200),
        ),
      );
      final streak = await repo.loadStreak();
      expect(streak.succeeded, isTrue);
      expect(streak.current, isNull);
      expect(streak.best, isNull);
    });
  });

  group('C-02a Home load with a failed streak pull', () {
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
            const MethodChannel(HealthConnectService.channelName),
            null,
          );
    });

    testWidgets('previously cached streak survives in memory, on disk, and '
        'on screen', (tester) async {
      final cache = HomeDataCache.instance;
      cache.applyVitals(
        const TodayVitals(
          heartRate: 70,
          activeCalories: 400,
          sleepMinutes: 400,
          logCountToday: 2,
        ),
      );
      cache.applyStreak(12, 30);
      await cache.persist();
      final seeded = jsonDecode(
        store.values[HomeDataCache.storageKey]!,
      ) as Map<String, dynamic>;
      expect(seeded['currentStreak'], 12);
      expect(seeded['bestStreak'], 30);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            weatherApi: WeatherApiClient(client: _mockWeatherClient()),
            healthRepository: _FailedStreakRepository(),
          ),
        ),
      );
      // Let the background load land (vitals resolve, streak fails)
      // and its persist flush.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The fresh vitals landed…
      expect(find.text('75'), findsOneWidget);
      // …but the failed streak pull did not blank the pills.
      expect(find.text('12'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);

      final s = cache.snapshot;
      expect(s.streakLoaded, isTrue);
      expect(s.currentStreak, 12);
      expect(s.bestStreak, 30);

      final persisted = jsonDecode(
        store.values[HomeDataCache.storageKey]!,
      ) as Map<String, dynamic>;
      expect(
        persisted['currentStreak'],
        12,
        reason:
            'a failed pull must not persist nulls over the '
            'cached streak',
      );
      expect(persisted['bestStreak'], 30);

      // Flush the staggered-entrance timers before teardown.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    });
  });
}
