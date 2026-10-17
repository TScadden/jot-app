import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

import 'health_connect_test.dart' show MemorySecureStore, serviceWith;

/// Round 12b — Health Connect permission-path hardening + slide transition.
///
/// 1. The round-12 "flash, then No permissions were granted" bug: the Health
///    Connect permission controller requires the `health_permissions`
///    meta-data in the app manifest to know which permissions the app may
///    request. These tests pin the Dart side of that contract: the runtime
///    request set must be non-empty and must match the manifest-declared
///    permissions exactly (the 14 record-type reads + history), so a future
///    drift between code and manifest fails loudly here instead of on device.
/// 2. Every native failure mode must surface as a visible error code —
///    never a silent empty result.
/// 3. The watch-icon navigation must slide in from the right (Material 3's
///    default zoom/fade reads as "just spawning in").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel(HealthConnectService.channelName), null);
  });

  group('permission set construction', () {
    test('request set is non-empty (empty set = instant HC close)', () {
      expect(HealthConnectService.requiredPermissions, isNotEmpty);
    });

    test('request set matches the manifest-declared permissions exactly', () {
      // Must stay in sync with:
      // - flutter/android/app/src/main/AndroidManifest.xml (<uses-permission>)
      // - flutter/android/app/src/main/res/values/health_permissions.xml
      //   (the 14 reads; history is granted implicitly, matching native)
      // - MainActivity.hcPermissions (Kotlin)
      const manifestDeclared = {
        'android.permission.health.READ_HEART_RATE',
        'android.permission.health.READ_SLEEP',
        'android.permission.health.READ_STEPS',
        'android.permission.health.READ_ACTIVE_CALORIES_BURNED',
        'android.permission.health.READ_TOTAL_CALORIES_BURNED',
        'android.permission.health.READ_BASAL_METABOLIC_RATE',
        'android.permission.health.READ_WEIGHT',
        'android.permission.health.READ_HEIGHT',
        'android.permission.health.READ_HEART_RATE_VARIABILITY',
        'android.permission.health.READ_RESPIRATORY_RATE',
        'android.permission.health.READ_OXYGEN_SATURATION',
        'android.permission.health.READ_RESTING_HEART_RATE',
        'android.permission.health.READ_POWER',
        'android.permission.health.READ_BLOOD_PRESSURE',
        'android.permission.health.READ_HEALTH_DATA_HISTORY',
      };
      expect(
        HealthConnectService.requiredPermissions,
        equals(manifestDeclared),
        reason: 'Dart request set drifted from the manifest — the HC '
            'permission UI would close immediately.',
      );
    });

    test('background access is never in the runtime request set', () {
      expect(
        HealthConnectService.requiredPermissions,
        isNot(contains(
            'android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND')),
      );
    });
  });

  group('failure modes surface visible error codes', () {
    test('NO_LAUNCHER propagates with its code', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async {
          if (call.method == 'requestPermissions') {
            throw PlatformException(code: 'NO_LAUNCHER', message: 'nope');
          }
          return null;
        },
      );
      try {
        await service.requestPermissions();
        fail('expected HealthConnectException');
      } on HealthConnectException catch (e) {
        expect(e.code, 'NO_LAUNCHER');
        expect(e.toString(), contains('[NO_LAUNCHER]'));
      }
    });

    test('EMPTY_PERMISSION_SET propagates with its code', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async {
          if (call.method == 'requestPermissions') {
            throw PlatformException(
                code: 'EMPTY_PERMISSION_SET', message: 'empty');
          }
          return null;
        },
      );
      try {
        await service.requestPermissions();
        fail('expected HealthConnectException');
      } on HealthConnectException catch (e) {
        expect(e.code, 'EMPTY_PERMISSION_SET');
      }
    });

    test('HC_UNAVAILABLE propagates with its code', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async {
          if (call.method == 'requestPermissions') {
            throw PlatformException(
                code: 'HC_UNAVAILABLE', message: 'not available');
          }
          return null;
        },
      );
      try {
        await service.requestPermissions();
        fail('expected HealthConnectException');
      } on HealthConnectException catch (e) {
        expect(e.code, 'HC_UNAVAILABLE');
        expect(e.toString(), contains('[HC_UNAVAILABLE]'));
      }
    });

    test('LAUNCH_FAILED propagates with its code', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async {
          if (call.method == 'requestPermissions') {
            throw PlatformException(code: 'LAUNCH_FAILED', message: 'boom');
          }
          return null;
        },
      );
      try {
        await service.requestPermissions();
        fail('expected HealthConnectException');
      } on HealthConnectException catch (e) {
        expect(e.code, 'LAUNCH_FAILED');
      }
    });
  });

  group('SlidePageRoute', () {
    testWidgets('slides in from the right and back out', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: _PushButton(),
        ),
      );

      // Sanity: target screen not visible yet.
      expect(find.text('Target'), findsNothing);

      await tester.tap(find.text('Push'));
      await tester.pump(); // dispatch the tap -> route pushed
      await tester.pump(const Duration(milliseconds: 150)); // mid-transition
      // Mid-transition the incoming page is offset to the right of zero.
      final midTransition = tester.getTopLeft(find.text('Target'));
      expect(midTransition.dx, greaterThan(0));

      await tester.pumpAndSettle();
      expect(find.text('Target'), findsOneWidget);

      // Back: the page slides back out to the right.
      await tester.tap(find.text('Pop'));
      await tester.pump(); // dispatch the tap -> pop starts
      await tester.pump(const Duration(milliseconds: 150)); // mid-reverse
      await tester.pumpAndSettle();
      expect(find.text('Target'), findsNothing);
    });
  });
}

class _PushButton extends StatelessWidget {
  const _PushButton();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            SlidePageRoute(builder: (_) => const _TargetScreen()),
          ),
          child: const Text('Push'),
        ),
      ),
    );
  }
}

class _TargetScreen extends StatelessWidget {
  const _TargetScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Target'),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Pop'),
            ),
          ],
        ),
      ),
    );
  }
}
