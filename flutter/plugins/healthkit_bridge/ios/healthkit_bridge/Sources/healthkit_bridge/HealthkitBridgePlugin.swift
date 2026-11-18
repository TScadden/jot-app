import Flutter
import UIKit

#if canImport(HealthKit)
import HealthKit
#endif

/// HealthKit bridge plugin (iOS counterpart to the Android
/// `health_connect_bridge` plugin).
///
/// Seam: this plugin registers a FlutterMethodChannel with EXACTLY
/// the same name the Android bridge serves —
/// `com.notel.notel.playground.flutter/health_connect`
/// (`HealthConnectService.channelName` in Dart) — so the single Dart
/// `HealthConnectService` drives both platforms and its existing
/// payload parsers are reused verbatim. This plugin declares only
/// iOS in its pubspec, so it never registers on Android, and the
/// Android plugin never registers on iOS.
///
/// Chunk 1 (skeleton): only `isAvailable` is implemented, answered
/// truthfully from `HKHealthStore.isHealthDataAvailable()`. Every
/// other bridge method returns `FlutterMethodNotImplemented`, which
/// surfaces in Dart as a `MissingPluginException` that
/// `HealthConnectService` already maps to its fail-closed
/// `NO_CHANNEL` paths. No payloads are faked in this chunk; the
/// HealthKit read queries land in later chunks and must return the
/// same map shapes the Kotlin bridge returns.
public class HealthkitBridgePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.notel.notel.playground.flutter/health_connect",
      binaryMessenger: registrar.messenger())
    let instance = HealthkitBridgePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      #if canImport(HealthKit)
        if #available(iOS 8.0, *) {
          result(HKHealthStore.isHealthDataAvailable())
        } else {
          result(false)
        }
      #else
        result(false)
      #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
