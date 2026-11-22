import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';

/// HealthKit chunk 4 — SDNN data-only (design 2026-11-11 §5,
/// BINDING):
/// - `HrvSdnnSample {t, ms}` is a separate typed series;
/// - the store row gains `hrvSdnnMs` BESIDE `hrvRmssdMs`, with
///   migration-safe serialization (old blobs parse with it null);
/// - the iOS capture leg writes SDNN days into `hrvSdnnMs` ONLY;
///   the Android capture never calls the SDNN read and never
///   writes the field;
/// - the score gate: `daily_score.dart` computes its HRV component
///   solely from `hrvRmssdMs` — an SDNN-only day yields a null HRV
///   component (SDNN scoring vs personal baselines is chunk 7).

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

/// Capture fake: empty sibling reads; the HRV legs are recorded so
/// a test can prove WHICH leg a platform's capture ran.
class _CaptureHc extends HealthConnectService {
  _CaptureHc({required bool ios, required this.sdnnSamples})
      : super(store: MemorySecureStore(), isIOSOverride: ios);

  final List<HrvSdnnSample> sdnnSamples;
  int sdnnCalls = 0;
  int rmssdCalls = 0;

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
          int days) async =>
      const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async {
    rmssdCalls++;
    return [
      (t: DateTime(2026, 11, 20, 3).millisecondsSinceEpoch, ms: 40.0, tier: 90),
      (t: DateTime(2026, 11, 20, 4).millisecondsSinceEpoch, ms: 50.0, tier: 90),
    ];
  }

  @override
  Future<List<HrvSdnnSample>> readHrvSdnnSamples(int days) async {
    sdnnCalls++;
    return sdnnSamples;
  }

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
          int days) async =>
      const [];

  @override
  Future<List<({String date, int count})>> readSpikeCounts(int days) async =>
      const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
    HealthHistorySync.debugResetFlight();
  });

  group('DailyBiometrics hrvSdnnMs — serialization (migration-safe)', () {
    test('a legacy blob without the key parses with hrvSdnnMs null', () {
      final row = DailyBiometrics.fromJson({
        'date': '2026-11-19',
        'restingHrBpm': 60,
        'hrvRmssdMs': 41.0,
      });
      expect(row, isNotNull);
      expect(row!.hrvSdnnMs, isNull);
      expect(row.hrvRmssdMs, 41.0);
    });

    test('a blob with the key parses the SDNN value; 0 stays a '
        'failed read (zero rule)', () {
      expect(
          DailyBiometrics.fromJson({'date': '2026-11-19', 'hrvSdnnMs': 48.5})!
              .hrvSdnnMs,
          48.5);
      expect(
          DailyBiometrics.fromJson({'date': '2026-11-19', 'hrvSdnnMs': 0})!
              .hrvSdnnMs,
          isNull);
    });

    test('toJson carries the key only when set; round-trip is lossless',
        () {
      const withSdnn =
          DailyBiometrics(date: '2026-11-19', hrvRmssdMs: 41.0, hrvSdnnMs: 52.0);
      final json = withSdnn.toJson();
      expect(json['hrvSdnnMs'], 52.0);
      expect(json['hrvRmssdMs'], 41.0);
      expect(DailyBiometrics.fromJson(json), withSdnn);

      const without =
          DailyBiometrics(date: '2026-11-19', hrvRmssdMs: 41.0);
      expect(without.toJson().containsKey('hrvSdnnMs'), isFalse);
    });

    test('the persisted store blob round-trips SDNN beside RMSSD', () async {
      final disk = <String, String>{
        HealthHistoryStore.storageKey: jsonEncode({
          'ownerEmail': null,
          'days': {
            '2026-11-19': {'date': '2026-11-19', 'restingHrBpm': 60},
          },
        }),
      };
      final store = _storeFor(disk);
      await store.warmFromDisk();
      final before = await store.readAll();
      // Legacy day: SDNN absent, not invented.
      expect(before['2026-11-19']!.hrvSdnnMs, isNull);

      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-11-19', hrvSdnnMs: 47.0),
      ]);
      final after = await store.readAll();
      expect(after['2026-11-19']!.hrvSdnnMs, 47.0);
      expect(after['2026-11-19']!.restingHrBpm, 60);
      expect(after['2026-11-19']!.hrvRmssdMs, isNull);

      final blob = jsonDecode(disk[HealthHistoryStore.storageKey]!)
          as Map<String, dynamic>;
      expect((blob['days'] as Map)['2026-11-19']['hrvSdnnMs'], 47.0);
    });

    test('merges keep the two HRV series separate in both directions',
        () async {
      final store = _storeFor(<String, String>{});
      await store.warmFromDisk();
      // An SDNN-only row creates its day.
      final added = await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-11-19', hrvSdnnMs: 47.0),
      ]);
      expect(added.daysAdded, 1);
      // An RMSSD refresh on the same day must not erase SDNN…
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-11-19', hrvRmssdMs: 39.0),
      ]);
      var row = (await store.readAll())['2026-11-19']!;
      expect(row.hrvSdnnMs, 47.0);
      expect(row.hrvRmssdMs, 39.0);
      // …and an SDNN refresh must not erase RMSSD.
      await store.mergeRefresh(const [
        DailyBiometrics(date: '2026-11-19', hrvSdnnMs: 49.0),
      ]);
      row = (await store.readAll())['2026-11-19']!;
      expect(row.hrvSdnnMs, 49.0);
      expect(row.hrvRmssdMs, 39.0);
      // mergeFillGaps fills SDNN only where it is absent.
      await store.mergeFillGaps(const [
        DailyBiometrics(date: '2026-11-19', hrvSdnnMs: 99.0),
        DailyBiometrics(date: '2026-11-18', hrvSdnnMs: 44.0),
      ]);
      final all = await store.readAll();
      expect(all['2026-11-19']!.hrvSdnnMs, 49.0);
      expect(all['2026-11-18']!.hrvSdnnMs, 44.0);
    });
  });

  group('readHrvSdnnSamples + attributeDailySdnn', () {
    test('the [{t, ms}] payload parses to HrvSdnnSample; malformed '
        'entries are skipped', () async {
      final channel = const MethodChannel(_channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readHrvSdnnSamples') {
          return [
            {'t': 1000, 'ms': 42.5},
            {'t': 'bad', 'ms': 10.0},
            {'t': 2000, 'ms': 50},
          ];
        }
        return null;
      });
      final service = HealthConnectService(
          channel: channel, store: MemorySecureStore());
      final out = await service.readHrvSdnnSamples(30);
      expect(out, [
        const HrvSdnnSample(t: 1000, ms: 42.5),
        const HrvSdnnSample(t: 2000, ms: 50.0),
      ]);
    });

    test('daily attribution: mean of usable samples; zero-ms dropped; '
        'out-of-window days excluded', () {
      final d20a = DateTime(2026, 11, 20, 3).millisecondsSinceEpoch;
      final d20b = DateTime(2026, 11, 20, 4).millisecondsSinceEpoch;
      final d21 = DateTime(2026, 11, 21, 3).millisecondsSinceEpoch;
      final out = attributeDailySdnn(
        [
          HrvSdnnSample(t: d20a, ms: 40.0),
          HrvSdnnSample(t: d20b, ms: 60.0),
          HrvSdnnSample(t: d20b, ms: 0.0), // failed read — dropped
          HrvSdnnSample(t: d21, ms: 55.0), // outside the date set
        ],
        {'2026-11-20'},
      );
      expect(out, {'2026-11-20': 50.0});
    });
  });

  group('capture wiring — the platform-split HRV leg', () {
    final now = DateTime(2026, 11, 21, 12);
    final sdnnSamples = [
      HrvSdnnSample(
          t: DateTime(2026, 11, 20, 3).millisecondsSinceEpoch, ms: 40.0),
      HrvSdnnSample(
          t: DateTime(2026, 11, 20, 4).millisecondsSinceEpoch, ms: 60.0),
    ];

    test('iOS capture: SDNN days write into hrvSdnnMs ONLY; the RMSSD '
        'read never runs', () async {
      final hc = _CaptureHc(ios: true, sdnnSamples: sdnnSamples);
      final store = _storeFor(<String, String>{});
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => now);
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(hc.sdnnCalls, 1);
      expect(hc.rmssdCalls, 0);
      final row = (await store.readAll())['2026-11-20'];
      expect(row, isNotNull);
      expect(row!.hrvSdnnMs, 50.0);
      expect(row.hrvRmssdMs, isNull);
    });

    test('Android capture: the SDNN read never runs and hrvSdnnMs is '
        'never written', () async {
      final hc = _CaptureHc(ios: false, sdnnSamples: sdnnSamples);
      final store = _storeFor(<String, String>{});
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => now);
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(hc.sdnnCalls, 0);
      expect(hc.rmssdCalls, 1);
      final row = (await store.readAll())['2026-11-20'];
      expect(row, isNotNull);
      expect(row!.hrvRmssdMs, 45.0);
      expect(row.hrvSdnnMs, isNull);
    });
  });

  group('the score gate (chunk 4 regression)', () {
    Map<String, DailyBiometrics> daysWithTarget(DailyBiometrics target) {
      final days = <String, DailyBiometrics>{};
      for (var i = 10; i <= 19; i++) {
        final date = '2026-11-$i';
        days[date] = DailyBiometrics(
          date: date,
          sleepMinutes: 480,
          restingHrBpm: 60,
          hrvRmssdMs: 40.0,
        );
      }
      days[target.date] = target;
      return days;
    }

    test('an SDNN-only day yields hrvRmssdMs == null and a null HRV '
        'score component', () {
      const target = DailyBiometrics(
        date: '2026-11-20',
        sleepMinutes: 480,
        restingHrBpm: 60,
        hrvSdnnMs: 55.0,
      );
      final days = daysWithTarget(target);
      expect(days['2026-11-20']!.hrvRmssdMs, isNull);
      final computation = computeDailyScore(days, '2026-11-20');
      expect(computation, isNotNull);
      // The HRV component is absent even though a full RMSSD
      // baseline exists: SDNN cannot reach the score in this chunk.
      expect(computation!.hrvScore, isNull);
      expect(computation.hrvMs, isNull);
      // The other components still compute (the null-component
      // reweighting carries the day).
      expect(computation.sleepScore, isNotNull);
      expect(computation.restingHrScore, isNotNull);
    });

    test('control: the same day WITH RMSSD scores its HRV component',
        () {
      const target = DailyBiometrics(
        date: '2026-11-20',
        sleepMinutes: 480,
        restingHrBpm: 60,
        hrvRmssdMs: 40.0,
      );
      final computation =
          computeDailyScore(daysWithTarget(target), '2026-11-20');
      expect(computation, isNotNull);
      expect(computation!.hrvScore, isNotNull);
      expect(computation.hrvMs, 40.0);
    });

    test('source pins: daily_score.dart reads RMSSD only; the capture '
        'site carries the settled chunk-7 decision', () {
      final scoreSource =
          File('lib/src/data/daily_score.dart').readAsStringSync();
      expect(scoreSource, contains('hrvRmssdMs'));
      expect(scoreSource, isNot(contains('hrvSdnnMs')));
      final syncSource =
          File('lib/src/data/health_history_sync.dart').readAsStringSync();
      expect(syncSource, contains('SETTLED DECISION (chunk 7)'));
      expect(syncSource, contains('hrvSdnnMs'));
    });
  });
}
