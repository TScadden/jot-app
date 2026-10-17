import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';

/// In-memory SecureStore fake — no platform channels, no real storage.
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

const _channelName = HealthConnectService.channelName;

HealthConnectService serviceWith({
  required MemorySecureStore store,
  Future<dynamic> Function(MethodCall call)? handler,
}) {
  final channel = MethodChannel(_channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, handler);
  return HealthConnectService(channel: channel, store: store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel(_channelName), null);
  });

  group('HealthConnectService', () {
    test('requiredPermissions has the 14 reads + history', () {
      expect(HealthConnectService.requiredPermissions.length, 15);
      expect(
          HealthConnectService.requiredPermissions,
          contains('android.permission.health.READ_HEART_RATE'));
      expect(
          HealthConnectService.requiredPermissions,
          contains('android.permission.health.READ_HEALTH_DATA_HISTORY'));
      expect(
          HealthConnectService.requiredPermissions,
          isNot(contains(
              'android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND')));
    });

    test('unavailable device → status unavailable, isConnected false',
        () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return false;
          throw PlatformException(code: 'HC_UNAVAILABLE');
        },
      );
      expect(await service.getStatus(), HealthConnectStatus.unavailable);
      expect(await service.isConnected(), false);
    });

    test('all permissions granted → connected + persisted', () async {
      final store = MemorySecureStore();
      final granted =
          HealthConnectService.requiredPermissions.toList();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return granted;
          throw UnimplementedError(call.method);
        },
      );
      expect(await service.getStatus(), HealthConnectStatus.connected);
      expect(await service.isConnected(), true);
      // Persisted for onboarding / fast first paint.
      expect(await service.hasPersistedConnection(), true);
    });

    test('no permissions granted → notConnected', () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return <String>[];
          throw UnimplementedError(call.method);
        },
      );
      expect(await service.getStatus(), HealthConnectStatus.notConnected);
      expect(await service.isConnected(), false);
      expect(await service.hasPersistedConnection(), false);
    });

    test('partial grant → partiallyConnected', () async {
      final store = MemorySecureStore();
      final partial =
          HealthConnectService.requiredPermissions.take(3).toList();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return partial;
          throw UnimplementedError(call.method);
        },
      );
      expect(
          await service.getStatus(), HealthConnectStatus.partiallyConnected);
      expect(await service.isConnected(), false);
    });

    test('requestPermissions success persists the granted set', () async {
      final store = MemorySecureStore();
      final granted =
          HealthConnectService.requiredPermissions.toList();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'requestPermissions') return granted;
          throw UnimplementedError(call.method);
        },
      );
      final result = await service.requestPermissions();
      expect(result, HealthConnectService.requiredPermissions);
      expect(await service.hasPersistedConnection(), true);
    });

    test('requestPermissions empty grant → visible IN_FLIGHT-style error path',
        () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'requestPermissions') {
            throw PlatformException(
                code: 'IN_FLIGHT', message: 'Already in progress.');
          }
          throw UnimplementedError(call.method);
        },
      );
      expect(
        () => service.requestPermissions(),
        throwsA(isA<HealthConnectException>().having(
            (e) => e.code, 'code', 'IN_FLIGHT')),
      );
    });

    test('missing plugin → NO_CHANNEL, never a silent hang', () async {
      final store = MemorySecureStore();
      // No mock handler installed for this fresh channel name variant:
      // use a channel with no handler → MissingPluginException.
      final service = HealthConnectService(
        channel: const MethodChannel('$_channelName-missing'),
        store: store,
      );
      expect(
        () => service.isAvailable(),
        throwsA(isA<HealthConnectException>().having(
            (e) => e.code, 'code', 'NO_CHANNEL')),
      );
    });

    test('disconnect clears persisted state', () async {
      final store = MemorySecureStore();
      final granted =
          HealthConnectService.requiredPermissions.toList();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return granted;
          if (call.method == 'requestPermissions') return granted;
          throw UnimplementedError(call.method);
        },
      );
      await service.requestPermissions();
      expect(await service.hasPersistedConnection(), true);
      await service.disconnect();
      expect(await service.hasPersistedConnection(), false);
    });

    test('persisted connection from onboarding reads true here', () async {
      // Simulates onboarding having persisted the connection: a fresh
      // service instance (as the connections screen would create) sees it.
      final store = MemorySecureStore();
      final onboardingService = serviceWith(store: store, handler: (call) async {
        if (call.method == 'requestPermissions') {
          return HealthConnectService.requiredPermissions.toList();
        }
        throw UnimplementedError(call.method);
      });
      await onboardingService.requestPermissions();

      final screenService = serviceWith(store: store, handler: (call) async {
        if (call.method == 'isAvailable') return true;
        if (call.method == 'getGrantedPermissions') {
          return HealthConnectService.requiredPermissions.toList();
        }
        throw UnimplementedError(call.method);
      });
      expect(await screenService.hasPersistedConnection(), true);
      expect(await screenService.isConnected(), true);
    });
  });

  group('ConnectionsScreen', () {
    testWidgets('unavailable device shows disabled row', (tester) async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return false;
          throw UnimplementedError(call.method);
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: ConnectionsScreen(healthConnectService: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Data connections'), findsOneWidget);
      expect(find.text('Not available on this device'), findsOneWidget);
      // Fitbit retirement card is always present.
      expect(find.text('Fitbit (Direct Sync)'), findsOneWidget);
      expect(find.text('No longer available'), findsOneWidget);
      expect(find.textContaining('Google retired the Fitbit Web API'),
          findsOneWidget);
    });

    testWidgets('not connected → Available row; tap grants → Connected',
        (tester) async {
      final store = MemorySecureStore();
      var granted = <String>[];
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return granted;
          if (call.method == 'requestPermissions') {
            granted = HealthConnectService.requiredPermissions.toList();
            return granted;
          }
          throw UnimplementedError(call.method);
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: ConnectionsScreen(healthConnectService: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text('No trackers connected yet.'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);

      await tester.tap(find.text('Available'));
      await tester.pumpAndSettle();
      // MF-3: the in-app disclosure precedes the permission UI.
      expect(find.text('Connect Health Connect?'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('No trackers connected yet.'), findsNothing);
    });

    testWidgets('denied (empty grant) shows a visible message',
        (tester) async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return <String>[];
          if (call.method == 'requestPermissions') return <String>[];
          throw UnimplementedError(call.method);
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: ConnectionsScreen(healthConnectService: service)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Available'));
      await tester.pumpAndSettle();
      // MF-3: the in-app disclosure precedes the permission UI.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('No permissions were granted.'), findsOneWidget);
      // Still not connected.
      expect(find.text('No trackers connected yet.'), findsOneWidget);
    });

    testWidgets('persisted connection shows Connected on first paint',
        (tester) async {
      final store = MemorySecureStore();
      await store.write(
          'hc_granted_permissions',
          HealthConnectService.requiredPermissions.join(','));
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') {
            return HealthConnectService.requiredPermissions.toList();
          }
          throw UnimplementedError(call.method);
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: ConnectionsScreen(healthConnectService: service)),
      );
      await tester.pump(); // first paint from persisted state
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('back button pops', (tester) async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return <String>[];
          throw UnimplementedError(call.method);
        },
      );
      var popped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionsScreen(
            healthConnectService: service,
            onBack: () => popped = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      expect(popped, true);
    });
  });
}
