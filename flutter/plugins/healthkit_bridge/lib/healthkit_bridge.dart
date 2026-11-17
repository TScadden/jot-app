/// HealthKit bridge plugin (iOS, local path package).
///
/// This library is intentionally empty of Dart API: the app talks to
/// the bridge through its own `HealthConnectService`
/// (lib/src/data/health_connect_service.dart) on the fixed channel
/// `com.notel.notel.playground.flutter/health_connect`. The package
/// exists so the Flutter tool's generated plugin registrant registers
/// [HealthkitBridgePlugin] on iOS, where it serves the same channel
/// name the Android `health_connect_bridge` plugin serves on Android.
/// The two native registrants never coexist on one platform: this
/// plugin declares only iOS, and `health_connect_bridge` declares
/// only Android.
library;
