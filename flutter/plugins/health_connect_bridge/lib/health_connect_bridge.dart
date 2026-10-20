/// Health Connect bridge plugin (Android, local path package).
///
/// This library is intentionally empty of Dart API: the app talks to
/// the bridge through its own `HealthConnectService`
/// (lib/src/data/health_connect_service.dart) on the fixed channel
/// `com.notel.notel.playground.flutter/health_connect`. The package
/// exists so the Flutter tool's generated plugin registrant registers
/// [HealthConnectBridgePlugin] on every FlutterEngine in the process —
/// including the WorkManager background engine, where MainActivity
/// handlers never existed and every bridge call used to fail with
/// MissingPluginException.
library;
