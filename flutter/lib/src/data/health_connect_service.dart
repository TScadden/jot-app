import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Round 12 — Health Connect service.
///
/// Standalone, onboarding-ready API with NO screen-specific coupling: both
/// the connections screen and the future onboarding connections step use
/// this same service. State is shared through persisted storage, so a
/// connection made in onboarding is already reflected here (and vice versa).
///
/// - [getStatus]: availability + live granted-permission check.
/// - [isConnected]: true when every required permission is granted.
/// - [requestPermissions]: launches the full Health Connect permission flow;
///   persists the granted set + timestamp on success.
/// - [disconnect]: Dart-side deactivation (clears persisted state; system
///   permissions can only be revoked in Health Connect settings, matching
///   the native app's behavior).
/// - [hasPersistedConnection]: fast storage-only read for first paint.
///
/// Scope: connection + permissions ONLY. No health data is read here.
class HealthConnectService {
  static const String channelName =
      'com.notel.notel.playground.flutter/health_connect';

  /// Must stay in sync with MainActivity.hcPermissions (Kotlin):
  /// the 14 record-type reads + history. Never includes background access.
  static const Set<String> requiredPermissions = {
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

  static const String _kGrantedKey = 'hc_granted_permissions';
  static const String _kConnectedAtKey = 'hc_connected_at';

  /// Native allows up to 5 minutes in the HC UI; Dart gives up just before
  /// so it can cancel the native pending request and stay retryable.
  static const Duration requestTimeout = Duration(minutes: 4, seconds: 30);

  final MethodChannel _channel;
  final SecureStore _store;

  HealthConnectService({MethodChannel? channel, SecureStore? store})
      : _channel = channel ?? const MethodChannel(channelName),
        _store = store ?? const FlutterSecureStore();

  /// True when Health Connect is installed and available on this device.
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException catch (e) {
      throw HealthConnectException(e.code, e.message ?? 'Availability check failed.');
    } on MissingPluginException {
      throw const HealthConnectException(
          'NO_CHANNEL', 'Health Connect bridge is not available.');
    }
  }

  /// The permissions currently granted to this app (empty when HC is
  /// unavailable or nothing was granted).
  Future<Set<String>> getGrantedPermissions() async {
    try {
      final granted = await _channel.invokeMethod<List>('getGrantedPermissions');
      return (granted ?? []).map((e) => e.toString()).toSet();
    } on PlatformException catch (e) {
      throw HealthConnectException(e.code, e.message ?? 'Could not read granted permissions.');
    } on MissingPluginException {
      throw const HealthConnectException(
          'NO_CHANNEL', 'Health Connect bridge is not available.');
    }
  }

  /// Live status: availability + granted-set check. Persists the granted
  /// set when everything required is granted.
  Future<HealthConnectStatus> getStatus() async {
    final available = await isAvailable();
    if (!available) return HealthConnectStatus.unavailable;
    final granted = await getGrantedPermissions();
    if (granted.containsAll(requiredPermissions)) {
      await _persist(granted);
      return HealthConnectStatus.connected;
    }
    if (granted.isEmpty) return HealthConnectStatus.notConnected;
    return HealthConnectStatus.partiallyConnected;
  }

  /// True when every required permission is currently granted.
  Future<bool> isConnected() async =>
      await getStatus() == HealthConnectStatus.connected;

  /// Fast storage-only read — for first paint before the live check lands.
  /// Shared with onboarding: a connection persisted there reads true here.
  Future<bool> hasPersistedConnection() async {
    final raw = await _store.read(_kGrantedKey);
    if (raw == null || raw.isEmpty) return false;
    final persisted = raw.split(',').toSet();
    return persisted.containsAll(requiredPermissions);
  }

  /// Launches the Health Connect permission UI. Returns the granted set
  /// (possibly partial or empty if the user declined). Throws
  /// [HealthConnectException] with a visible code on failure/timeout.
  /// Safe to call from the connections screen OR onboarding — no UI coupling.
  Future<Set<String>> requestPermissions() async {
    try {
      final granted = await _channel
          .invokeMethod<List>('requestPermissions')
          .timeout(requestTimeout);
      final set = (granted ?? []).map((e) => e.toString()).toSet();
      await _persist(set);
      return set;
    } on TimeoutException {
      // Keep native + Dart in sync so a retry is never wedged.
      try {
        await _channel.invokeMethod('cancelRequest');
      } catch (_) {}
      throw const HealthConnectException('REQUEST_TIMEOUT',
          'The permission request timed out. Please try again.');
    } on PlatformException catch (e) {
      throw HealthConnectException(
          e.code, e.message ?? 'Permission request failed.');
    } on MissingPluginException {
      throw const HealthConnectException(
          'NO_CHANNEL', 'Health Connect bridge is not available.');
    }
  }

  /// Dart-side deactivation: clears persisted state. System permissions can
  /// only be revoked in Health Connect settings (same as the native app).
  Future<void> disconnect() async {
    await _store.delete(_kGrantedKey);
    await _store.delete(_kConnectedAtKey);
  }

  /// Opens the Health Connect system settings screen.
  Future<void> openHealthConnectSettings() async {
    try {
      await _channel.invokeMethod('openHealthConnectSettings');
    } on PlatformException catch (e) {
      throw HealthConnectException(
          e.code, e.message ?? 'Could not open Health Connect settings.');
    } on MissingPluginException {
      throw const HealthConnectException(
          'NO_CHANNEL', 'Health Connect bridge is not available.');
    }
  }

  Future<void> _persist(Set<String> granted) async {
    await _store.write(_kGrantedKey, granted.join(','));
    await _store.write(
        _kConnectedAtKey, DateTime.now().toUtc().toIso8601String());
  }
}

enum HealthConnectStatus {
  unavailable,
  notConnected,
  partiallyConnected,
  connected,
}

class HealthConnectException implements Exception {
  final String code;
  final String message;

  const HealthConnectException(this.code, this.message);

  @override
  String toString() => 'HealthConnectException[$code]: $message';
}

/// Minimal storage abstraction so tests can inject an in-memory fake.
/// Production uses Android Keystore-backed flutter_secure_storage.
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureStore implements SecureStore {
  final FlutterSecureStorage _storage;

  const FlutterSecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
