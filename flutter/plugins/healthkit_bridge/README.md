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

- **Chunk 1 (skeleton):** the plugin registers on the shared
  channel and implements only `isAvailable`, answered truthfully from
  `HKHealthStore.isHealthDataAvailable()`. Every other bridge method
  returns `FlutterMethodNotImplemented`, which Dart surfaces as a
  `MissingPluginException` that `HealthConnectService` already maps
  to its fail-closed `NO_CHANNEL` paths. No payloads are faked.
- **Chunks 2+3 (reads):** real HealthKit queries behind the same
  contract — heart rate, resting HR (+ history), steps (+ history),
  active/total calories (+ histories), blood pressure correlations,
  respiratory rate, oxygen saturation, latest weight/height, spike
  counts, exercise sessions, sleep minutes/stages/history, and a
  real-read `probeReadAccess`. HRV is SDNN-only on iOS and travels
  through the separate `readHrvSdnnSamples` series (design §5);
  `readHrvSamples` / `readHrvRmssd` stay unimplemented, as do
  `getGrantedPermissions` (HealthKit never discloses read denial —
  no fabricated grant list), `requestPermissions` (chunk 6), and the
  Android-only file/settings/keep-alive methods.

The app's iOS build is Swift Package Manager based (no Podfile;
`FlutterGeneratedPluginSwiftPackage`), so the SPM manifest at
`ios/healthkit_bridge/Package.swift` is the build definition the
tooling consumes. The sibling `ios/healthkit_bridge.podspec` is kept
alongside it, matching the dual SPM + CocoaPods layout the current
Flutter plugin template generates, for CocoaPods consumers.
