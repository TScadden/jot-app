# captureError call-site allowlist (Juno Ruling 2026-10-27, C7)

`CrashReporting.captureError` (lib/src/data/crash_reporting.dart) may
be called ONLY from the app-level catch sites listed here. Juno
reviews this list with the diff; adding a call site means adding a
row here in the same change, with the same review.

Rules for every call site (C7):

- Only the exception TYPE and a static, code-defined message are
  sent. The helper enforces this mechanically: the original
  exception object and its rendered message never reach the SDK.
- A call site must never pass (in any argument, including an
  interpolated string): API response bodies, log/note text,
  medication names or values, health values, file names or paths,
  calendar titles, document text, tokens, or URLs.
- The helper is fire-and-forget and never throws; call sites keep
  their pre-existing behaviour exactly (same return values, same
  user-visible outcome) — the report is additive only.

| # | Call site | Static message | Why this site |
|---|-----------|----------------|---------------|
| 1 | `lib/main.dart` — `_bootstrap`, `SessionStore().readEmail()` catch | `bootstrap session read failed` | App-level bootstrap catch; previously silent. The underlying store error can embed the stored value (account data), hence type-only reporting. |
| 2 | `lib/main.dart` — `_bootstrap`, `NotificationBootstrap.initialize(...)` catch | `notification bootstrap failed` | App-level bootstrap catch; previously silent. Plugin errors can embed device/notification content. |
| 3 | `lib/src/data/health_history_sync.dart` — `HealthHistorySync` capture catch | `health history capture failed` | App-level sync catch; previously silent (returned false). Health Connect read errors can embed health values — type-only reporting is load-bearing here. |

Global handlers (FlutterError.onError, PlatformDispatcher.onError,
runZonedGuarded) are NOT call sites on this list: they are the C6
bootstrap in crash_reporting.dart itself, and every event they
produce still passes through the C1 allowlist scrub in beforeSend.

## Lab-hook extension (Step-2 evidence, 2026-10-27)

NOT captureError call sites — Lab-flavor-only evidence triggers,
all gated by `CrashReporting.isLabFlavor()` in Dart, reachable
only from the Lab-only Settings hook card, long-press only:

| Trigger | Path | Purpose |
|---|---|---|
| Native crash | `CrashReporting.triggerNativeTestCrash` → MethodChannel `com.notel.notel.playground.flutter/crash_test` → Kotlin handler in MainActivity, registered ONLY when the applicationId is the Lab identity, which posts a fatal RuntimeException to the main thread | Juno Condition 1: exercise the native/Java Sentry pipeline that bypasses the Dart beforeSend allowlist |
| Canary event | `CrashReporting.triggerLabCanaryTestEvent` → `Sentry.captureEvent(CrashReporting.buildLabCanaryEvent())` through the live `CrashReporting.run` init | R11 console-level repeat (Juno Step-2 verdict §7): the nine synthetic canary seeds, in the gate's event positions plus mechanism.data and runtime name/version (Condition 6), inspected in the received event's raw JSON |

Neither trigger is a production code path: the hook card does not
render in the prod flavor, both Dart triggers refuse to act when
`isLabFlavor()` is false, and the Kotlin channel is never
registered under the production applicationId.
