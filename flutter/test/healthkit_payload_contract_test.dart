import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';

/// In-memory SecureStore fake — no platform channels, no real storage.
/// (Same shape as the fake in health_connect_test.dart.)
class MemorySecureStore implements SecureStore {
  final Map<String, String> _map = {};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
}

/// Payload-contract tests for the iOS `healthkit_bridge` plugin
/// (chunks 2+3). The Swift side returns the SAME map shapes the
/// Kotlin bridge returns; these tests feed HealthKit-shaped payload
/// maps (exactly what the Swift queries emit, including the iOS-only
/// shapes the design doc mandates) through the EXISTING Dart parsers
/// in `HealthConnectService` and pin the internal models that come
/// out. No Dart production code changes were needed for any of them.
const _channelName = 'com.notel.notel.playground.flutter/health_connect';

int _ms(DateTime d) => d.millisecondsSinceEpoch;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  HealthConnectService serviceReturning(Map<String, dynamic> responses) {
    final channel = const MethodChannel(_channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (responses.containsKey(call.method)) return responses[call.method];
      return null;
    });
    return HealthConnectService(channel: channel, store: MemorySecureStore());
  }

  group('HealthKit payloads → HR / resting / steps / calories parsers', () {
    test('heart rate samples: [{t, bpm}] list parses to HrSample', () async {
      final t0 = _ms(DateTime(2026, 11, 21, 8, 0));
      final service = serviceReturning({
        'readHeartRateSamples': [
          {'t': t0, 'bpm': 62},
          {'t': t0 + 60000, 'bpm': 71},
        ],
      });
      final out = await service.readHeartRateSamples('2026-11-21');
      expect(out, hasLength(2));
      expect(out[0].timeMs, t0);
      expect(out[0].bpm, 62);
      expect(out[1].bpm, 71);
    });

    test('resting HR history: [{date, bpm}] parses; absent day stays absent',
        () async {
      final service = serviceReturning({
        'readRestingHrHistory': [
          {'date': '2026-11-20', 'bpm': 58},
          // 2026-11-21 has NO resting record on iOS: the Swift side
          // emits no entry (no synthesized average fallback, design
          // §4), so the parser must not invent one either.
          {'date': '2026-11-22', 'bpm': 60},
        ],
      });
      final out = await service.readRestingHrHistory(3);
      expect(out, hasLength(2));
      expect(out.map((e) => e.date), ['2026-11-20', '2026-11-22']);
      expect(out.first.bpm, 58);
    });

    test('steps: a value parses; null (no points) stays null, never 0',
        () async {
      final withData = serviceReturning({'readSteps': 8432});
      expect(await withData.readSteps('2026-11-21'), 8432);

      final noData = serviceReturning({'readSteps': null});
      expect(await noData.readSteps('2026-11-21'), isNull);
    });

    test('calories history: active-shaped and total-fallback days both '
        'pass through as [{date, kcal}]', () async {
      // The active-vs-total fallback is resolved natively (Swift:
      // active primary, active+basal only when active is absent for
      // the day). Both resolutions arrive in the same [{date, kcal}]
      // shape and must parse identically.
      final service = serviceReturning({
        'readCaloriesHistory': [
          {'date': '2026-11-20', 'kcal': 640}, // active present
          {'date': '2026-11-21', 'kcal': 1980}, // total fallback day
        ],
        'readActiveCalories': 640,
      });
      final history = await service.readCaloriesHistory(2);
      expect(history.map((e) => e.kcal), [640, 1980]);
      expect(await service.readActiveCalories('2026-11-20'), 640);
    });

    test('blood pressure: [{t, sys, dia}] parses to BpRecord', () async {
      final t0 = _ms(DateTime(2026, 11, 21, 9, 30));
      final service = serviceReturning({
        'readBloodPressure': [
          {'t': t0, 'sys': 118, 'dia': 76},
        ],
      });
      final out = await service.readBloodPressure(7);
      expect(out, hasLength(1));
      expect(out.single.systolic, 118);
      expect(out.single.diastolic, 76);
      expect(out.single.timeEpochMs, t0);
    });

    test('spike counts: [{date, count}] parses and a real 0 is kept',
        () async {
      final service = serviceReturning({
        'readSpikeCounts': [
          {'date': '2026-11-20', 'count': 3},
          {'date': '2026-11-21', 'count': 0},
        ],
      });
      final out = await service.readSpikeCounts(2);
      expect(out, hasLength(2));
      expect(out.last.count, 0);
    });

    test('latest weight/height and respiratory/oxygen doubles parse',
        () async {
      final service = serviceReturning({
        'readLatestWeightKg': 81.4,
        'readLatestHeightCm': 177.8,
        'readRespiratoryRate': 14.0,
        'readOxygenSaturation': 98.0,
      });
      expect(await service.readLatestWeightKg(), 81.4);
      expect(await service.readLatestHeightCm(), 177.8);
      expect(await service.readRespiratoryRate('2026-11-21'), 14.0);
      expect(await service.readOxygenSaturation('2026-11-21'), 98.0);
    });
  });

  group('HealthKit payloads → sleep mapping (chunk 3)', () {
    // A staged iOS 16+ night as the Swift side ships it via
    // readSleepHistory: session span = in-bed/asleep span, date =
    // wake/end date, awake intervals from `awake` samples, deep
    // intervals from asleepDeep samples (asleepCore → light and
    // asleepREM → REM cross via readSleepStages, below).
    Map<String, dynamic> stagedSession() {
      final start = DateTime(2026, 11, 20, 22, 30);
      final end = DateTime(2026, 11, 21, 6, 30);
      return {
        'date': '2026-11-21',
        'startMs': _ms(start),
        'endMs': _ms(end),
        'awake': [
          [_ms(DateTime(2026, 11, 21, 2, 0)), _ms(DateTime(2026, 11, 21, 2, 20))],
        ],
        'deep': [
          [_ms(DateTime(2026, 11, 20, 23, 0)), _ms(DateTime(2026, 11, 20, 23, 40))],
          [_ms(DateTime(2026, 11, 21, 1, 0)), _ms(DateTime(2026, 11, 21, 1, 30))],
        ],
      };
    }

    test('staged session summarizes: 480 span − 20 awake = 460, deep 70',
        () async {
      final service = serviceReturning({
        'readSleepHistory': [stagedSession()],
      });
      final out = await service.readSleepHistory(1);
      expect(out, hasLength(1));
      expect(out.single.date, '2026-11-21');
      expect(out.single.mins, 460);
      expect(out.single.deep, 70);
    });

    test('pre-iOS 16 stage-less session: empty stage lists, totals compute',
        () async {
      final start = DateTime(2026, 11, 20, 22, 0);
      final end = DateTime(2026, 11, 21, 6, 0);
      final service = serviceReturning({
        'readSleepHistory': [
          {
            'date': '2026-11-21',
            'startMs': _ms(start),
            'endMs': _ms(end),
            'awake': <dynamic>[],
            'deep': <dynamic>[],
          },
        ],
      });
      final out = await service.readSleepHistory(1);
      expect(out, hasLength(1));
      // The full in-bed/asleep span is the night's total…
      expect(out.single.mins, 480);
      // …and deep is the raw 0 pass-through (no stage data exists);
      // callers apply the founder zero rule — it is never presented
      // as measured deep sleep.
      expect(out.single.deep, 0);
    });

    test('readSleepStages staged payload: core→light, deep, REM map through',
        () async {
      final service = serviceReturning({
        'readSleepStages': {
          'minutesAsleep': 460,
          'deepMinutes': 70,
          'lightMinutes': 260,
          'remMinutes': 130,
          'efficiency': 96,
        },
      });
      final stages = await service.readSleepStages('2026-11-21');
      expect(stages, isNotNull);
      expect(stages!.minutesAsleep, 460);
      expect(stages.deepMinutes, 70);
      expect(stages.lightMinutes, 260);
      expect(stages.remMinutes, 130);
      expect(stages.efficiency, 96);
    });

    test('readSleepStages stage-less payload: stage fields are null, '
        'never 0-as-data', () async {
      // The Swift side OMITS the stage keys for a pre-iOS 16
      // stage-less session (design §4); the parser must surface
      // null stage fields while totals still compute.
      final service = serviceReturning({
        'readSleepStages': {
          'minutesAsleep': 452,
          'efficiency': 94,
        },
      });
      final stages = await service.readSleepStages('2026-11-21');
      expect(stages, isNotNull);
      expect(stages!.minutesAsleep, 452);
      expect(stages.efficiency, 94);
      expect(stages.deepMinutes, isNull);
      expect(stages.lightMinutes, isNull);
      expect(stages.remMinutes, isNull);
    });
  });

  group('SDNN typing separation (design §5)', () {
    test('an SDNN-shaped payload cannot enter the RMSSD sample parser: '
        'entries without a tier are dropped, never attributed', () async {
      // The Swift SDNN series is [{t, ms}] with NO tier key, under
      // its own method name. If SDNN values were ever routed into
      // readHrvSamples, the existing parser must refuse them (tier
      // is required), so attributeDailyHrv can never see SDNN.
      final t0 = _ms(DateTime(2026, 11, 21, 3, 0));
      final service = serviceReturning({
        'readHrvSamples': [
          {'t': t0, 'ms': 42.0}, // SDNN-shaped: no tier
        ],
      });
      final out = await service.readHrvSamples(1);
      expect(out, isEmpty);
      expect(attributeDailyHrv(out, {'2026-11-21'}), isEmpty);
    });

    test('genuine RMSSD payloads ({t, ms, tier}) still parse + attribute',
        () async {
      final t0 = _ms(DateTime(2026, 11, 21, 3, 0));
      final service = serviceReturning({
        'readHrvSamples': [
          {'t': t0, 'ms': 40.0, 'tier': 90},
          {'t': t0 + 3600000, 'ms': 50.0, 'tier': 90},
        ],
      });
      final out = await service.readHrvSamples(1);
      expect(out, hasLength(2));
      final daily = attributeDailyHrv(out, {'2026-11-21'});
      expect(daily['2026-11-21'], 45.0);
    });

    test('Swift source pins: SDNN has its own method; the RMSSD methods '
        'are not implemented in Swift', () {
      final swift = File(
              'plugins/healthkit_bridge/ios/healthkit_bridge/Sources/'
              'healthkit_bridge/HealthkitBridgePlugin.swift')
          .readAsStringSync();
      // The separate SDNN series exists under its own name and type.
      expect(swift, contains('"readHrvSdnnSamples"'));
      expect(swift, contains('.heartRateVariabilitySDNN'));
      // SDNN is never routed through the RMSSD-shaped methods: the
      // Swift switch has no case for them, so they fall through to
      // FlutterMethodNotImplemented.
      expect(swift, isNot(contains('case "readHrvSamples"')));
      expect(swift, isNot(contains('case "readHrvRmssd"')));
      // Sleep stage mapping names are in the Swift source (§4).
      expect(swift, contains('.asleepCore'));
      expect(swift, contains('.asleepDeep'));
      expect(swift, contains('.asleepREM'));
      // Read-only guarantee: the read-type set exists, and the
      // authorization request (added in chunk 6, superseding this
      // test's chunk-2/3 "not yet implemented" pin) asks to SHARE
      // nothing — the toShare set is empty, read types only.
      expect(swift, contains('healthReadTypes'));
      expect(swift, contains('requestAuthorization'));
      expect(swift, contains('toShare: Set<HKSampleType>()'));
    });
  });
}
