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
| 4 | `lib/src/data/gem_service.dart` — `GemService.ensureLoaded` storage-read catch | `gems storage load failed` | Grants fix (Nov 20, 2026): the load catch previously swallowed the error and left the service silently unloaded, disabling every gem grant with no trace (production ledger: 0 rows). Storage plugin errors can embed the stored value — type-only reporting. |
| 5 | `lib/src/data/gem_service.dart` — `GemService._flushPending` grant-request catch | `gems grant request failed` | Grants fix (Nov 20, 2026): a thrown grant request previously left the key queued with no record anywhere. Only the exception type is sent — the grant key (a date/kind token) is never passed to the helper. |
| 6 | `lib/src/data/badge_store.dart` — `BadgeService.ensureLoaded` storage-read catch | `badges storage load failed` | Grants fix (Nov 20, 2026): same silent-unload failure as #4, on the badge grant path. Type-only reporting for the same reason. |
| 7 | `lib/src/data/badge_store.dart` — `BadgeService._flushPending` grant-request catch | `badges grant request failed` | Grants fix (Nov 20, 2026): same invisible-queue failure as #5, on the badge grant path. The grant key is never passed to the helper. |
| 8 | `lib/src/features/home/home_screen.dart` — `_syncGemsOnOpen` catch | `gems app-open sync failed` | Grants fix (Nov 20, 2026): the app-open gems sync is fail-soft by design (unawaited from the settle); its catch-all previously swallowed every escaped error. The error is also recorded in GemService's diagnostics state. |
| 9 | `lib/src/features/home/home_screen.dart` — `_syncBadgesOnOpen` catch | `badges app-open sync failed` | Grants fix (Nov 20, 2026): same fail-soft app-open wrapper as #8, on the badge path; also recorded in BadgeService's diagnostics state. |
| 10 | `lib/src/data/chest_service.dart` — `ChestService.openChest` transport catch | `chest open failed` | Chests (Nov 26, 2026): a thrown open request previously left no trace; the chest stays in the inbox and the retry replays the idempotent server call. Only the exception type is sent — the chest id is never passed to the helper. |

Global handlers (FlutterError.onError, PlatformDispatcher.onError,
runZonedGuarded) are NOT call sites on this list: they are the C6
bootstrap in crash_reporting.dart itself, and every event they
produce still passes through the C1 allowlist scrub in beforeSend.
