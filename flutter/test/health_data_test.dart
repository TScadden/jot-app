import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';

import 'test_helpers.dart';

/// Local-time epoch millis helper — grouping and hour checks are all
/// device-local, so tests build times in the local zone.
int _at(int y, int mo, int d, int h, [int min = 0]) =>
    DateTime(y, mo, d, h, min).millisecondsSinceEpoch;

List<WindowDay> _window() => sevenDayWindow();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('daytimeHeartRateAvg', () {
    test('excludes night readings (daytime-only rule)', () {
      final samples = [
        HrSample(timeMs: _at(2026, 10, 11, 10), bpm: 70),
        HrSample(timeMs: _at(2026, 10, 11, 12), bpm: 80),
        HrSample(timeMs: _at(2026, 10, 11, 23), bpm: 120),
      ];
      expect(daytimeHeartRateAvg(samples), 75);
    });

    test('boundary hours 7 and 21 count as daytime', () {
      final samples = [
        HrSample(timeMs: _at(2026, 10, 11, 7), bpm: 70),
        HrSample(timeMs: _at(2026, 10, 11, 21), bpm: 80),
        HrSample(timeMs: _at(2026, 10, 11, 6, 59), bpm: 40),
        HrSample(timeMs: _at(2026, 10, 11, 22), bpm: 40),
      ];
      expect(daytimeHeartRateAvg(samples), 75);
    });

    test('no daytime samples falls back to overall non-zero average', () {
      final samples = [
        HrSample(timeMs: _at(2026, 10, 11, 23), bpm: 110),
        HrSample(timeMs: _at(2026, 10, 11, 2), bpm: 120),
      ];
      expect(daytimeHeartRateAvg(samples), 115);
    });

    test('all-zero samples return null, never 0', () {
      final samples = [
        HrSample(timeMs: _at(2026, 10, 11, 10), bpm: 0),
        HrSample(timeMs: _at(2026, 10, 11, 12), bpm: 0),
      ];
      expect(daytimeHeartRateAvg(samples), isNull);
    });

    test('zero bpm samples are excluded before averaging', () {
      final samples = [
        HrSample(timeMs: _at(2026, 10, 11, 10), bpm: 0),
        HrSample(timeMs: _at(2026, 10, 11, 12), bpm: 70),
      ];
      expect(daytimeHeartRateAvg(samples), 70);
    });

    test('empty list returns null', () {
      expect(daytimeHeartRateAvg(const []), isNull);
    });
  });

  group('computeDailyHrSummary', () {
    test('two >=100 readings 3 min apart = 1 spike event', () {
      final base = _at(2026, 10, 11, 10);
      final samples = [
        HrSample(timeMs: _at(2026, 10, 11, 9), bpm: 70),
        HrSample(timeMs: base, bpm: 105),
        HrSample(timeMs: base + 3 * 60 * 1000, bpm: 110),
        HrSample(timeMs: _at(2026, 10, 11, 11), bpm: 72),
      ];
      final s = computeDailyHrSummary('2026-10-11', samples)!;
      expect(s.spikeCount, 1);
      expect(s.daySpikeCount, 1);
      expect(s.nightSpikeCount, 0);
    });

    test('two >=100 readings 6 min apart = 2 spike events', () {
      final base = _at(2026, 10, 11, 10);
      final samples = [
        HrSample(timeMs: base, bpm: 105),
        HrSample(timeMs: base + 6 * 60 * 1000, bpm: 110),
      ];
      final s = computeDailyHrSummary('2026-10-11', samples)!;
      expect(s.spikeCount, 2);
    });

    test('day/night split uses the event start hour', () {
      final samples = [
        HrSample(timeMs: _at(2026, 10, 11, 9), bpm: 105),
        HrSample(timeMs: _at(2026, 10, 11, 23), bpm: 108),
      ];
      final s = computeDailyHrSummary('2026-10-11', samples)!;
      expect(s.daySpikeCount, 1);
      expect(s.nightSpikeCount, 1);
      expect(s.spikeCount, 2);
    });

    test('baseline is the 10th percentile', () {
      final samples = [
        for (var i = 0; i < 20; i++)
          HrSample(timeMs: _at(2026, 10, 11, 10, i), bpm: 60 + i),
      ];
      final s = computeDailyHrSummary('2026-10-11', samples)!;
      // (20 * 0.10).toInt() = 2 → third-smallest value.
      expect(s.baseline, 62);
      expect(s.min, 60);
      expect(s.max, 79);
      expect(s.maxDelta, 79 - 62);
    });

    test('awakeAvg is daytime-only with fallback to overall avg', () {
      final samples = [
        HrSample(timeMs: _at(2026, 10, 11, 10), bpm: 70),
        HrSample(timeMs: _at(2026, 10, 11, 12), bpm: 80),
        HrSample(timeMs: _at(2026, 10, 11, 23), bpm: 120),
      ];
      final s = computeDailyHrSummary('2026-10-11', samples)!;
      expect(s.awakeAvg, 75); // daytime only, not (70+80+120)/3
      expect(s.avg, 90); // overall average
    });

    test('zero samples excluded; empty after exclusion returns null', () {
      final samples = [
        HrSample(timeMs: _at(2026, 10, 11, 10), bpm: 0),
        HrSample(timeMs: _at(2026, 10, 11, 12), bpm: 70),
        HrSample(timeMs: _at(2026, 10, 11, 13), bpm: 80),
      ];
      final s = computeDailyHrSummary('2026-10-11', samples)!;
      expect(s.avg, 75);
      expect(
          computeDailyHrSummary('2026-10-11', [
            HrSample(timeMs: _at(2026, 10, 11, 10), bpm: 0),
          ]),
          isNull);
      expect(computeDailyHrSummary('2026-10-11', const []), isNull);
    });
  });

  group('snapshot builders', () {
    test('sleep: hours value, avg text, zero/null → null points', () {
      final w = _window();
      final dateStrs = [for (final d in w) d.dateStr];
      final labels = [for (final d in w) d.dayLabel];
      final data = buildSleepMetric(dateStrs, labels, {
        dateStrs[5]: 450, // yesterday
        dateStrs[6]: 480, // today
        dateStrs[4]: 0, // failed read → null point
      });
      expect(data.points[6].value, 8.0);
      expect(data.points[5].value, 7.5);
      expect(data.points[4].value, isNull);
      expect(data.averageOrTotalText, '7-Day Avg: 7h 45m');
      expect(data.emptyMessage, isNull);

      final empty = buildSleepMetric(dateStrs, labels, const {});
      expect(empty.averageOrTotalText, 'Not enough sleep data yet');
      expect(empty.emptyMessage, 'Not enough sleep data yet');
      expect(empty.points.every((p) => p.value == null), isTrue);
    });

    test('resting HR: zero → null, avg text, missing → empty message', () {
      final w = _window();
      final dateStrs = [for (final d in w) d.dateStr];
      final labels = [for (final d in w) d.dayLabel];
      final data = buildRestingHrMetric(
          dateStrs, labels, {dateStrs[6]: 62, dateStrs[5]: 0});
      expect(data.points[6].value, 62.0);
      expect(data.points[5].value, isNull); // 0 is a failed read
      expect(data.averageOrTotalText, '7-Day Avg: 62 bpm');

      final empty = buildRestingHrMetric(dateStrs, labels, const {});
      expect(empty.averageOrTotalText, 'No heart rate data logged past 7 days');
      expect(empty.emptyMessage, 'No heart rate data logged past 7 days');
    });

    test('spikes: 0 is real; null input → could-not-load state', () {
      final w = _window();
      final dateStrs = [for (final d in w) d.dateStr];
      final labels = [for (final d in w) d.dayLabel];
      final data =
          buildSpikesMetric(dateStrs, labels, {dateStrs[6]: 3});
      expect(data.points[6].value, 3.0);
      expect(data.points[0].value, 0.0); // real zero
      expect(data.averageOrTotalText, '7-Day Total: 3 spikes');
      expect(data.emptyMessage, isNull);

      final failed = buildSpikesMetric(dateStrs, labels, null);
      expect(failed.averageOrTotalText, 'Could not load HR spike records');
      expect(failed.emptyMessage, 'Could not load HR spike records');
    });

    test('calories: zero → null, total text, missing → empty message', () {
      final w = _window();
      final dateStrs = [for (final d in w) d.dateStr];
      final labels = [for (final d in w) d.dayLabel];
      final data = buildCaloriesMetric(
          dateStrs, labels, {dateStrs[6]: 250, dateStrs[5]: 0});
      expect(data.points[6].value, 250.0);
      expect(data.points[5].value, isNull);
      expect(data.averageOrTotalText, '7-Day Total: 250 kcal');

      final empty = buildCaloriesMetric(dateStrs, labels, const {});
      expect(empty.averageOrTotalText, 'No calorie data logged past 7 days');
    });

    test('habits: completion pct math and empty messages', () {
      final w = _window();
      final dateStrs = [for (final d in w) d.dateStr];
      final labels = [for (final d in w) d.dayLabel];
      final today = dateStrs[6];
      final yesterday = dateStrs[5];
      final data = buildHabitsMetric(dateStrs, labels, [
        HabitDto(id: '1', title: 'Water', logs: [today, yesterday]),
        HabitDto(id: '2', title: 'Meds', logs: [today]),
      ], true);
      expect(data.points[6].value, 100.0);
      expect(data.points[5].value, 50.0);
      expect(data.points[0].value, 0.0);
      // (100 + 50 + 0*5) / 7 = 21.4 → 21
      expect(data.averageOrTotalText, '7-Day Completion: 21%');
      expect(data.emptyMessage, isNull);

      final noHabits = buildHabitsMetric(dateStrs, labels, const [], true);
      expect(noHabits.averageOrTotalText, 'No habits configured');
      expect(noHabits.emptyMessage, 'No habits configured');
    });

    test('logs: grouped by device-local day, 0 real', () {
      final w = _window();
      final dateStrs = [for (final d in w) d.dateStr];
      final labels = [for (final d in w) d.dayLabel];
      final now = DateTime.now();
      final data = buildLogsMetric(dateStrs, labels, [
        DateTime(now.year, now.month, now.day, 9).millisecondsSinceEpoch,
        DateTime(now.year, now.month, now.day, 21).millisecondsSinceEpoch,
        DateTime(now.year, now.month, now.day - 1, 12)
            .millisecondsSinceEpoch,
      ]);
      expect(data.points[6].value, 2.0);
      expect(data.points[5].value, 1.0);
      expect(data.points[0].value, 0.0);
      expect(data.averageOrTotalText, '7-Day Total: 3 logs');
    });

    test('BP: HC + manual combine into daily sys/dia averages', () {
      final w = _window();
      final dateStrs = [for (final d in w) d.dateStr];
      final labels = [for (final d in w) d.dayLabel];
      final now = DateTime.now();
      final todayMs =
          DateTime(now.year, now.month, now.day, 10).millisecondsSinceEpoch;
      final data = buildBpMetric(dateStrs, labels, [
        // HC record
        BpRecord(systolic: 120, diastolic: 80, timeEpochMs: todayMs),
        // Manual log, same day
        BpRecord(
            systolic: 124, diastolic: 82, timeEpochMs: todayMs + 3600000),
      ]);
      expect(data.points[6].value, 122.0);
      expect(data.points[6].secondaryValue, 81.0);
      expect(data.averageOrTotalText, '7-Day Avg: 122/81 mmHg');
      expect(data.isAvailable, isTrue);

      final empty = buildBpMetric(dateStrs, labels, const []);
      expect(empty.isAvailable, isFalse);
      expect(empty.averageOrTotalText, 'No blood pressure records found');
      expect(empty.emptyMessage, 'No blood pressure records found');
    });
  });

  group('HealthConnectService typed reads (mocked channel)', () {
    late _MemStore store;
    setUp(() => store = _MemStore());

    HealthConnectService serviceWith(
        Future<dynamic> Function(MethodCall call) handler) {
      final channel = MethodChannel(HealthConnectService.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      return HealthConnectService(channel: channel, store: store);
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(HealthConnectService.channelName), null);
    });

    test('readHeartRateSamples parses [{t, bpm}]', () async {
      final svc = serviceWith((call) async {
        expect(call.method, 'readHeartRateSamples');
        expect(call.arguments['dateStr'], '2026-10-11');
        return [
          {'t': 1000, 'bpm': 72},
          {'t': 2000, 'bpm': 75},
        ];
      });
      final samples = await svc.readHeartRateSamples('2026-10-11');
      expect(samples.map((s) => s.bpm), [72, 75]);
      expect(samples.map((s) => s.timeMs), [1000, 2000]);
    });

    test('PlatformException → null/empty, code kept in debug string', () async {
      final svc = serviceWith((call) async {
        throw PlatformException(code: 'READ_FAILED');
      });
      expect(await svc.readActiveCalories('today'), isNull);
      expect(await svc.readHeartRateSamples('today'), isEmpty);
      expect(await svc.readRestingHrHistory(7), isEmpty);
      expect(svc.lastReadErrorCode, 'READ_FAILED');
    });

    test('history lists parse {date, value} records', () async {
      final svc = serviceWith((call) async {
        if (call.method == 'readRestingHrHistory') {
          return [
            {'date': '2026-10-11', 'bpm': 58},
          ];
        }
        if (call.method == 'readCaloriesHistory') {
          return [
            {'date': '2026-10-11', 'kcal': 320},
          ];
        }
        if (call.method == 'readBloodPressure') {
          return [
            {'t': 1000, 'sys': 120, 'dia': 80},
          ];
        }
        return null;
      });
      final rhr = await svc.readRestingHrHistory(7);
      expect(rhr.single, (date: '2026-10-11', bpm: 58));
      final cal = await svc.readCaloriesHistory(7);
      expect(cal.single, (date: '2026-10-11', kcal: 320));
      final bp = await svc.readBloodPressure(7);
      expect(bp.single.systolic, 120);
      expect(bp.single.diastolic, 80);
    });
  });

  group('HealthRepository', () {
    HealthRepository repoWith({
      required Future<dynamic> Function(MethodCall call) channelHandler,
      required http.Client httpClient,
      required FakeSessionStore sessionStore,
    }) {
      final channel = MethodChannel(HealthConnectService.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, channelHandler);
      return HealthRepository(
        hc: HealthConnectService(
            channel: channel, store: _MemStore()),
        backend: TabsBackend(client: httpClient, sessionStore: sessionStore),
      );
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(HealthConnectService.channelName), null);
    });

    Future<dynamic> Function(MethodCall) okChannel({
      int sleepMinutes = 480,
      int activeCalories = 250,
      List<Map<String, Object>> hrSamples = const [],
    }) {
      return (call) async {
        switch (call.method) {
          case 'isAvailable':
            return true;
          case 'getGrantedPermissions':
            return HealthConnectService.requiredPermissions.toList();
          case 'readSleepMinutes':
            return sleepMinutes;
          case 'readActiveCalories':
            return activeCalories;
          case 'readHeartRateSamples':
            return hrSamples;
          case 'readRestingHrHistory':
            return <Map<String, Object>>[];
          case 'readCaloriesHistory':
            return <Map<String, Object>>[];
          case 'readBloodPressure':
            return <Map<String, Object>>[];
        }
        throw PlatformException(code: 'NOPE');
      };
    }

    test('loadTodayVitals combines HC vitals with the backend log count',
        () async {
      final store = FakeSessionStore()..token = 'tok';
      final now = DateTime.now();
      final todayStart =
          DateTime(now.year, now.month, now.day, 8).millisecondsSinceEpoch;
      final repo = repoWith(
        channelHandler: okChannel(hrSamples: [
          {'t': _at(now.year, now.month, now.day, 10), 'bpm': 70},
          {'t': _at(now.year, now.month, now.day, 12), 'bpm': 80},
        ]),
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/sync/pull') {
            return http.Response(
                '{"entries":[{"timestamp":$todayStart}],"profile":{}}', 200);
          }
          return http.Response('not found', 404);
        }),
        sessionStore: store,
      );

      final vitals = await repo.loadTodayVitals(connected: true);
      expect(vitals.heartRate, 75);
      expect(vitals.activeCalories, 250);
      expect(vitals.sleepMinutes, 480);
      expect(vitals.logCountToday, 1);
    });

    test('not connected → biometrics null, log count still real', () async {
      final store = FakeSessionStore()..token = 'tok';
      final now = DateTime.now();
      final todayStart =
          DateTime(now.year, now.month, now.day, 8).millisecondsSinceEpoch;
      final repo = repoWith(
        channelHandler: okChannel(),
        httpClient: MockClient((_) async => http.Response(
            '{"entries":[{"timestamp":$todayStart}],"profile":{}}', 200)),
        sessionStore: store,
      );

      final vitals = await repo.loadTodayVitals(connected: false);
      expect(vitals.heartRate, isNull);
      expect(vitals.activeCalories, isNull);
      expect(vitals.sleepMinutes, isNull);
      expect(vitals.logCountToday, 1);
    });

    test('channel failures → nulls/zeros, never throws', () async {
      final store = FakeSessionStore()..token = 'tok';
      final repo = repoWith(
        channelHandler: (_) async =>
            throw PlatformException(code: 'READ_FAILED'),
        httpClient: MockClient((_) async =>
            throw http.ClientException('down')),
        sessionStore: store,
      );

      final vitals = await repo.loadTodayVitals(connected: true);
      expect(vitals.heartRate, isNull);
      expect(vitals.activeCalories, isNull);
      expect(vitals.sleepMinutes, isNull);
      expect(vitals.logCountToday, 0);

      final streak = await repo.loadStreak();
      expect(streak.current, isNull);
      expect(streak.best, isNull);
    });

    test('loadSnapshot sleep → real avg text from mocked channel', () async {
      final store = FakeSessionStore();
      final repo = repoWith(
        channelHandler: okChannel(sleepMinutes: 480),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        sessionStore: store,
      );
      final data = await repo.loadSnapshot(SnapshotMetric.sleepHours);
      expect(data.metric, SnapshotMetric.sleepHours);
      expect(data.points, hasLength(7));
      expect(data.averageOrTotalText, '7-Day Avg: 8h 0m');
    });

    test('loadSnapshot logs → real counts from the backend', () async {
      final store = FakeSessionStore()..token = 'tok';
      final now = DateTime.now();
      final ts = DateTime(now.year, now.month, now.day, 9).millisecondsSinceEpoch;
      final repo = repoWith(
        channelHandler: okChannel(),
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/sync/pull') {
            return http.Response('{"entries":[{"timestamp":$ts}]}', 200);
          }
          return http.Response('not found', 404);
        }),
        sessionStore: store,
      );
      final data = await repo.loadSnapshot(SnapshotMetric.logs);
      expect(data.averageOrTotalText, '7-Day Total: 1 logs');
      expect(data.points.last.value, 1.0);
    });

    test('loadSnapshot habits → pct from the backend', () async {
      final store = FakeSessionStore()..token = 'tok';
      final now = DateTime.now();
      final today =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final repo = repoWith(
        channelHandler: okChannel(),
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/habits') {
            return http.Response(
                '{"habits":[{"id":"1","title":"Water","logs":["$today"]},{"id":"2","title":"Meds","logs":[]}]}',
                200);
          }
          return http.Response('not found', 404);
        }),
        sessionStore: store,
      );
      final data = await repo.loadSnapshot(SnapshotMetric.habitCompletion);
      expect(data.averageOrTotalText, '7-Day Completion: 7%');
    });
  });
}

/// In-memory SecureStore fake — no platform channels.
class _MemStore implements SecureStore {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
  @override
  Future<void> delete(String key) async => _map.remove(key);
}
