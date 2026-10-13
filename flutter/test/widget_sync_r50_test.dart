import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';

/// Round 50 — snapshot → widget-payload mapping for the Android
/// home-screen vitals widget. The mapping must mirror Home exactly:
/// biometric 0 / null is a failed read and renders "--", never a
/// number; the log count is real even at 0; sleep reuses the strip's
/// formatter; signed-out payloads carry no numbers at all.
HomeCacheSnapshot _snap({
  TodayVitals? vitals,
  bool vitalsLoaded = true,
  int? currentStreak,
  bool streakLoaded = true,
}) {
  return HomeCacheSnapshot(
    vitals: vitals,
    vitalsLoaded: vitalsLoaded,
    currentStreak: currentStreak,
    bestStreak: null,
    streakLoaded: streakLoaded,
  );
}

void main() {
  group('WidgetSync.buildPayload', () {
    test('normal values map preformatted, streak in the flame cell',
        () {
      final payload = WidgetSync.buildPayload(
        _snap(
          vitals: const TodayVitals(
            heartRate: 72,
            activeCalories: 310,
            sleepMinutes: 482,
            logCountToday: 3,
          ),
          currentStreak: 12,
        ),
        signedIn: true,
      );
      expect(payload.signedIn, isTrue);
      expect(payload.heartRate, '72');
      // The flame cell is the streak days, NOT active calories.
      expect(payload.streak, '12');
      expect(payload.logs, '3');
      expect(payload.sleep, '8h2m');
    });

    test('heart rate 0 is a failed read → "--", never "0"', () {
      final payload = WidgetSync.buildPayload(
        _snap(
          vitals: const TodayVitals(heartRate: 0, logCountToday: 1),
          currentStreak: 2,
        ),
        signedIn: true,
      );
      expect(payload.heartRate, '--');
    });

    test('heart rate null → "--"', () {
      final payload = WidgetSync.buildPayload(
        _snap(vitals: const TodayVitals(logCountToday: 1)),
        signedIn: true,
      );
      expect(payload.heartRate, '--');
    });

    test('missing vitals section → biometrics "--", logs read 0', () {
      final payload = WidgetSync.buildPayload(
        _snap(vitals: null, vitalsLoaded: false, currentStreak: 4),
        signedIn: true,
      );
      expect(payload.heartRate, '--');
      expect(payload.sleep, '--');
      // Same rule as the strip: `v?.logCountToday ?? 0`.
      expect(payload.logs, '0');
      expect(payload.streak, '4');
    });

    test('sleep 0 → "--" and sleep null → "--"', () {
      final zero = WidgetSync.buildPayload(
        _snap(vitals: const TodayVitals(sleepMinutes: 0)),
        signedIn: true,
      );
      expect(zero.sleep, '--');
      final missing = WidgetSync.buildPayload(
        _snap(vitals: const TodayVitals()),
        signedIn: true,
      );
      expect(missing.sleep, '--');
    });

    test('sleep 426 formats via the strip formatter → "7h6m"', () {
      final payload = WidgetSync.buildPayload(
        _snap(vitals: const TodayVitals(sleepMinutes: 426)),
        signedIn: true,
      );
      expect(payload.sleep, '7h6m');
    });

    test('sleep under an hour formats as minutes only', () {
      final payload = WidgetSync.buildPayload(
        _snap(vitals: const TodayVitals(sleepMinutes: 45)),
        signedIn: true,
      );
      expect(payload.sleep, '45m');
    });

    test('logs 0 is honest → "0", not "--"', () {
      final payload = WidgetSync.buildPayload(
        _snap(vitals: const TodayVitals(logCountToday: 0)),
        signedIn: true,
      );
      expect(payload.logs, '0');
    });

    test('streak null → "--"; streak 0 is an honest count', () {
      final missing = WidgetSync.buildPayload(
        _snap(vitals: const TodayVitals(), currentStreak: null),
        signedIn: true,
      );
      expect(missing.streak, '--');
      final zero = WidgetSync.buildPayload(
        _snap(vitals: const TodayVitals(), currentStreak: 0),
        signedIn: true,
      );
      expect(zero.streak, '0');
    });

    test('signed-out payload carries no numbers at all', () {
      final payload = WidgetSync.buildPayload(
        _snap(
          vitals: const TodayVitals(
            heartRate: 72,
            sleepMinutes: 426,
            logCountToday: 5,
          ),
          currentStreak: 9,
        ),
        signedIn: false,
      );
      expect(payload.signedIn, isFalse);
      expect(payload.heartRate, '--');
      expect(payload.streak, '--');
      expect(payload.logs, '--');
      expect(payload.sleep, '--');
      // No digit from the snapshot may leak into any cell.
      for (final value in payload.toMap().values) {
        expect(value.toString(), isNot(matches(RegExp(r'[0-9]'))));
      }
    });
  });

  group('WidgetSync bridge (push / clear)', () {
    final saved = <String, Object?>{};
    var updateCount = 0;

    setUp(() {
      saved.clear();
      updateCount = 0;
      WidgetSync.debugSetBridge(
        save: (key, value) async => saved[key] = value,
        update: () async => updateCount++,
      );
    });

    tearDown(WidgetSync.debugResetBridge);

    test('pushSnapshot saves the payload under the native keys and '
        'requests an update', () async {
      await WidgetSync.pushSnapshot(
        _snap(
          vitals: const TodayVitals(
            heartRate: 68,
            sleepMinutes: 426,
            logCountToday: 2,
          ),
          currentStreak: 7,
        ),
        signedIn: true,
      );
      expect(saved[WidgetSync.keySignedIn], isTrue);
      expect(saved[WidgetSync.keyHeartRate], '68');
      expect(saved[WidgetSync.keyStreak], '7');
      expect(saved[WidgetSync.keyLogs], '2');
      expect(saved[WidgetSync.keySleep], '7h6m');
      expect(updateCount, 1);
    });

    test('clear wipes the values, sets signed-in false, and '
        'requests an update', () async {
      await WidgetSync.pushSnapshot(
        _snap(
          vitals: const TodayVitals(heartRate: 68, logCountToday: 2),
          currentStreak: 7,
        ),
        signedIn: true,
      );
      await WidgetSync.clear();
      expect(saved[WidgetSync.keySignedIn], isFalse);
      expect(saved[WidgetSync.keyHeartRate], '--');
      expect(saved[WidgetSync.keyStreak], '--');
      expect(saved[WidgetSync.keyLogs], '--');
      expect(saved[WidgetSync.keySleep], '--');
      expect(updateCount, 2);
    });

    test('a failing bridge never throws out of pushSnapshot or clear',
        () async {
      WidgetSync.debugSetBridge(
        save: (key, value) async => throw StateError('bridge down'),
        update: () async => throw StateError('bridge down'),
      );
      await expectLater(
        WidgetSync.pushSnapshot(_snap(), signedIn: true),
        completes,
      );
      await expectLater(WidgetSync.clear(), completes);
    });
  });
}
