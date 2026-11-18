# healthkit_bridge

Local Flutter plugin carrying the Tabs health MethodChannel bridge on
iOS (`com.notel.notel.playground.flutter/health_connect`). It is the
iOS-only counterpart to `health_connect_bridge` (Android), modeled on
that plugin's structure: the app talks to both bridges through the one
Dart `HealthConnectService`
(`flutter/lib/src/data/health_connect_service.dart`) on the fixed
channel name, and each plugin's generated registrant serves that
channel on its own platform only. This plugin declares **only** the
iOS platform in its pubspec, so it never registers on Android and the
Android path stays byte-identical.

## Payload-contract rule

The Swift side must return the **same map payloads** the Kotlin
`HealthConnectBridgePlugin` returns for each method — same method
names, same argument shapes, same result shapes, same error
vocabulary — so the existing Dart parsers in `HealthConnectService`
are reused verbatim on both platforms. Never invent an iOS-only
payload shape; if a HealthKit type has no Android analogue (for
example SDNN vs RMSSD), that is a separate, deliberately typed series
decided in its own chunk, never a silent remapping onto the Android
shape.

## Chunk status

- **Chunk 1 (this skeleton):** the plugin registers on the shared
  channel and implements only `isAvailable`, answered truthfully from
  `HKHealthStore.isHealthDataAvailable()`. Every other bridge method
  returns `FlutterMethodNotImplemented`, which Dart surfaces as a
  `MissingPluginException` that `HealthConnectService` already maps
  to its fail-closed `NO_CHANNEL` paths. No payloads are faked.
- Later chunks add the HealthKit read queries (heart rate, resting
  heart rate, sleep, steps, energy, SDNN) behind the same contract.

The app's iOS build is Swift Package Manager based (no Podfile;
`FlutterGeneratedPluginSwiftPackage`), so the SPM manifest at
`ios/healthkit_bridge/Package.swift` is the build definition the
tooling consumes. The sibling `ios/healthkit_bridge.podspec` is kept
alongside it, matching the dual SPM + CocoaPods layout the current
Flutter plugin template generates, for CocoaPods consumers.
