# health_connect_bridge

Local Flutter plugin carrying the Tabs Health Connect MethodChannel
bridge (`com.notel.notel.playground.flutter/health_connect`), extracted
from `MainActivity` so the generated plugin registrant registers the
handlers on **every** FlutterEngine in the app process — the main
engine and the WorkManager background engine alike. Before the
extraction the handlers existed only in MainActivity's engine, so the
Daily Score background runner's bridge calls failed with
`MissingPluginException` on device.

The handler bodies are a transplant, not a rewrite: channel name,
method names, argument/result shapes, error codes and details, the
runtime permission set (14 record-type reads + HISTORY), timeouts,
chunking and partial-result contracts are unchanged. No Dart change
was required.

Seams worth knowing:

- **Permission launcher stays Activity-owned.** A plugin has no
  `onCreate`, and team lessons pin launcher registration to
  `MainActivity.onCreate` via `activityResultRegistry`.
  MainActivity registers the launcher exactly as before, publishes it
  to `HealthConnectBridgePlugin.activityPermissionLauncher`, and
  forwards the result callback to
  `HealthConnectBridgePlugin.deliverPermissionResult`. The plugin
  instance that launched a request claims the result route at launch
  time. In a background engine the published launcher is null and
  `requestPermissions` returns the pre-existing `NO_LAUNCHER` error.
- **Coroutine scope is engine-scoped.** Reads run in a
  `SupervisorJob + Dispatchers.Main` scope created on engine attach
  and cancelled on engine detach (previously: the Activity's
  `lifecycleScope`).
- **Activity-bound methods fail deliberately in the background.**
  `openHealthConnectSettings` returns `NO_SETTINGS` and
  `exportCsvFile` returns `CSV_EXPORT_FAILED` when no Activity is
  attached, instead of crashing or hanging. The Dart background
  runner never calls them.
- **Context** is the application context from the plugin binding;
  HealthConnectClient behavior is identical.
