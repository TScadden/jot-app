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

/// The exact channel contract shared by the Android
/// `health_connect_bridge` plugin (Kotlin) and the iOS
/// `healthkit_bridge` plugin (Swift). Written as a literal here on
/// purpose: this test pins the contract string itself, so it must
/// not derive the expected value from the constant under test.
const _contractChannelName =
    'com.notel.notel.playground.flutter/health_connect';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel(_contractChannelName), null);
  });

  HealthConnectService serviceWithHandler(
      Future<dynamic> Function(MethodCall call)? handler) {
    final channel = MethodChannel(_contractChannelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    return HealthConnectService(
        channel: channel, store: MemorySecureStore());
  }

  group('HealthKit bridge seam — channel contract', () {
    test('HealthConnectService.channelName is the exact shared contract',
        () {
      expect(HealthConnectService.channelName, _contractChannelName);
    });

    test('isAvailable fails closed: a null reply reads as false', () async {
      final service = serviceWithHandler((call) async => null);
      expect(await service.isAvailable(), isFalse);
    });

    test('isAvailable fails closed: a false reply reads as false',
        () async {
      final service = serviceWithHandler((call) async {
        if (call.method == 'isAvailable') return false;
        return null;
      });
      expect(await service.isAvailable(), isFalse);
    });

    test(
        'no native handler (FlutterMethodNotImplemented on iOS, or no '
        'registrant) maps to HealthConnectException NO_CHANNEL', () async {
      // No mock handler installed: the messenger answers with a
      // MissingPluginException, exactly as a not-implemented native
      // method does. This is the chunk-1 iOS skeleton contract for
      // every bridge method except isAvailable.
      final service = HealthConnectService(
        channel: const MethodChannel(_contractChannelName),
        store: MemorySecureStore(),
      );
      expect(
        () => service.isAvailable(),
        throwsA(isA<HealthConnectException>()
            .having((e) => e.code, 'code', 'NO_CHANNEL')),
      );
    });
  });

  group('HealthKit bridge seam — plugin shape (on-disk pubspecs)', () {
    // flutter test runs with the app package root (flutter/) as the
    // working directory.
    final pluginPubspec =
        File('plugins/healthkit_bridge/pubspec.yaml').readAsStringSync();
    final appPubspec = File('pubspec.yaml').readAsStringSync();

    test('healthkit_bridge declares the iOS platform only', () {
      expect(pluginPubspec, contains('name: healthkit_bridge'));
      expect(pluginPubspec, contains('pluginClass: HealthkitBridgePlugin'));
      // The platforms block lists ios and nothing else: no android
      // entry means the plugin can never register on Android.
      final platformsBlock =
          pluginPubspec.split('platforms:').last.trim();
      expect(platformsBlock, contains('ios:'));
      expect(platformsBlock, isNot(contains('android:')));
      expect(platformsBlock, isNot(contains('macos:')));
      expect(platformsBlock, isNot(contains('web:')));
    });

    test('app depends on healthkit_bridge by path, next to the '
        'Android bridge', () {
      expect(
        appPubspec,
        contains('healthkit_bridge:\n    path: plugins/healthkit_bridge'),
      );
      expect(
        appPubspec,
        contains(
            'health_connect_bridge:\n    path: plugins/health_connect_bridge'),
      );
    });

    test('the Swift registrant uses the exact contract channel name',
        () {
      final swift = File(
              'plugins/healthkit_bridge/ios/healthkit_bridge/Sources/'
              'healthkit_bridge/HealthkitBridgePlugin.swift')
          .readAsStringSync();
      expect(swift, contains('name: "$_contractChannelName"'));
      expect(swift, contains('HKHealthStore.isHealthDataAvailable()'));
      expect(swift, contains('FlutterMethodNotImplemented'));
    });
  });
}
