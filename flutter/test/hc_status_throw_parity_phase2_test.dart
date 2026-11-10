import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';

/// Report Reliability Phase 2, PR-1 — FIX round fixtures for Vera's
/// Item 3 NO SIGN (getStatus()/isConnected() throw parity).
///
/// Channel-mock harness in Vera's C1/C2/C3 shapes
/// (vera-logs/probes/vera_probe_pr1_test.dart, group C), asserting
/// BASE (2f9a709d) expectations against the probe-core head:
///
/// - C1: isAvailable() throws AVAIL_BOOM, grants full, probe ok →
///   base THREW the availability exception (code AND message),
///   made no further bridge calls, and persisted nothing. The
///   pre-fix head returned `connected` AND persisted.
/// - C2: isAvailable() throws, partial grant → base threw; the
///   pre-fix head returned `partiallyConnected`.
/// - C3: getGrantedPermissions() throws GRANT_BOOM → code parity
///   at the pre-fix head, but the MESSAGE was replaced with the
///   generic "Health Connect status check failed."; base
///   propagated the native message.
///
/// The fix: the probe records each layer's actual failure
/// (HealthConnectException, code + message) on the snapshot and
/// getStatus() rethrows the availability failure first, then the
/// grant failure, before any grant-derived return or persist.
/// probeAvailability() itself still never throws.

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  final allGranted = HealthConnectService.requiredPermissions.toList();

  HealthConnectService serviceWith({
    required MemorySecureStore store,
    required Future<dynamic> Function(MethodCall call) handler,
    List<String>? calls,
  }) {
    final channel = MethodChannel(_channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls?.add(call.method);
      return handler(call);
    });
    return HealthConnectService(channel: channel, store: store);
  }

  group('getStatus() throw parity (Vera Item 3, C-shapes)', () {
    test(
        'C1 isAvailable throws + full grant → getStatus throws the '
        'availability exception (code AND message), persists nothing',
        () async {
      final store = MemorySecureStore();
      final calls = <String>[];
      final service = serviceWith(
        store: store,
        calls: calls,
        handler: (call) async {
          if (call.method == 'isAvailable') {
            throw PlatformException(
                code: 'AVAIL_BOOM', message: 'avail broke');
          }
          if (call.method == 'getGrantedPermissions') return allGranted;
          if (call.method == 'probeReadAccess') return true;
          throw UnimplementedError(call.method);
        },
      );
      await expectLater(
        service.getStatus(),
        throwsA(isA<HealthConnectException>()
            .having((e) => e.code, 'code', 'AVAIL_BOOM')
            .having((e) => e.message, 'message', 'avail broke')),
      );
      // Base made no further bridge calls after the availability
      // throw — the grant layer is never consulted.
      expect(calls, ['isAvailable']);
      expect(await service.hasPersistedConnection(), isFalse);
      // isConnected() inherits the throw via getStatus().
      await expectLater(
        service.isConnected(),
        throwsA(isA<HealthConnectException>()
            .having((e) => e.code, 'code', 'AVAIL_BOOM')),
      );
      expect(await service.hasPersistedConnection(), isFalse);
    });

    test(
        'C2 isAvailable throws + partial grant → getStatus throws the '
        'availability exception (code AND message), persists nothing',
        () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') {
            throw PlatformException(
                code: 'AVAIL_BOOM', message: 'avail broke');
          }
          if (call.method == 'getGrantedPermissions') {
            return allGranted.sublist(1);
          }
          throw UnimplementedError(call.method);
        },
      );
      await expectLater(
        service.getStatus(),
        throwsA(isA<HealthConnectException>()
            .having((e) => e.code, 'code', 'AVAIL_BOOM')
            .having((e) => e.message, 'message', 'avail broke')),
      );
      expect(await service.hasPersistedConnection(), isFalse);
    });

    test(
        'C3 grant fetch throws → getStatus throws with the grant code '
        'AND the native message intact, persists nothing', () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') {
            throw PlatformException(
                code: 'GRANT_BOOM', message: 'grant layer broke');
          }
          throw UnimplementedError(call.method);
        },
      );
      await expectLater(
        service.getStatus(),
        throwsA(isA<HealthConnectException>()
            .having((e) => e.code, 'code', 'GRANT_BOOM')
            .having((e) => e.message, 'message', 'grant layer broke')),
      );
      expect(await service.hasPersistedConnection(), isFalse);
    });
  });
}
