package com.notel.notel.playground.flutter

import io.sentry.ScopesAdapter
import io.sentry.Sentry
import io.sentry.SentryOptions

/// Post-init registration of the native C1 scrub — Juno Ruling
/// 2026-10-28, Sentry Step-2 §1.2 (Route 2 via Option B).
///
/// `SentryClient.executeBeforeSend` reads `options.getBeforeSend()`
/// LIVE from the options object at capture time (sentry-java
/// 8.61.1, SentryClient.java), so assigning the scrub to the live
/// options after the plugin's `SentryFlutter.init` has run reaches
/// every native capture after registration — JVM uncaught
/// exceptions, ANRs as events, handled Java exceptions, and Event
/// items re-captured from the disk outbox (OutboxSender deserialises
/// Event items and calls `scopes.captureEvent`, which runs the same
/// executeBeforeSend).
///
/// This REPLACES the sentry_flutter plugin's tagging-only callback
/// in the single beforeSend slot (replace, do not chain — §1.3: the
/// tags it set are outside the C1 tag allowlist).
///
/// The live options are reached exactly the way the plugin itself
/// reaches them (`ScopesAdapter.getInstance().options`, see
/// SentryFlutterPlugin.loadContexts). Nothing here initialises the
/// SDK, sets a distinct ID, or touches session state (§1.2(3),
/// §1.5 sessions note): when the SDK never initialised (empty DSN,
/// the C11 inert path) there is nothing to register on and this
/// object is never called — inertness is untouched by construction.
object NativeScrubRegistration {

    /**
     * Replaces the live native beforeSend with [NativeCrashScrub].
     *
     * Returns a report map for the Dart side:
     * - `sdkEnabled`: whether the native SDK is initialised at all;
     * - `beforeSendPresent`: whether a beforeSend callback occupied
     *   the slot before registration (the plugin's tagging-only
     *   callback is expected to be present);
     * - `replaced`: whether the slot now holds the scrub (verified
     *   by identity after assignment).
     *
     * Never throws: a registration failure must surface to Dart as a
     * report / channel error, never as a startup crash.
     */
    fun register(): Map<String, Any> {
        if (!Sentry.isEnabled()) {
            return mapOf(
                "sdkEnabled" to false,
                "beforeSendPresent" to false,
                "replaced" to false
            )
        }
        val options = ScopesAdapter.getInstance().options
        val presentBefore = options.getBeforeSend() != null
        val callback = SentryOptions.BeforeSendCallback { event, _ ->
            NativeCrashScrub.scrub(event)
        }
        options.setBeforeSend(callback)
        val replaced = options.getBeforeSend() === callback
        return mapOf(
            "sdkEnabled" to true,
            "beforeSendPresent" to presentBefore,
            "replaced" to replaced
        )
    }
}
