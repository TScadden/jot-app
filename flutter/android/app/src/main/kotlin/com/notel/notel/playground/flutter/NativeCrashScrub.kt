package com.notel.notel.playground.flutter

import io.sentry.SentryEvent
import io.sentry.protocol.App
import io.sentry.protocol.Device
import io.sentry.protocol.Mechanism
import io.sentry.protocol.OperatingSystem
import io.sentry.protocol.SentryException
import io.sentry.protocol.SentryRuntime
import io.sentry.protocol.SentryStackFrame
import io.sentry.protocol.SentryStackTrace

/// Native (Java-pipeline) C1 scrub — Juno Ruling 2026-10-28,
/// Sentry Step-2 §1.2–§1.3, §1.5. Registered post-init on the live
/// native options by [NativeScrubRegistration] as the single
/// `SentryOptions.BeforeSendCallback`, REPLACING the sentry_flutter
/// plugin's tagging-only callback in that slot (replace, not chain).
///
/// The callback receives the fully enriched Java event (it runs
/// after all Java event processors, including
/// DefaultAndroidEventProcessor at order 8000) and rebuilds it to
/// the same allowlist as Dart `CrashReporting.scrubEvent`:
///
/// - `user`, `request`, `breadcrumbs`, `extra`, `modules`,
///   `message`, `serverName`, non-default `fingerprint`, `threads`,
///   `transaction`, `logger` and deserialized `unknown` fields are
///   removed entirely (never emptied-and-kept).
/// - Exception values are replaced with the static marker,
///   character for character identical to the Dart marker; types are
///   sanitised with the same identifier rule as Dart
///   `sanitizeExceptionType`.
/// - Stack frames keep code identifiers only (module, function,
///   file name, line/column, in-app flag): no frame variables, no
///   source-context lines, no absolute paths.
/// - Mechanisms are rebuilt to the Condition 6 rule: type
///   (identifier-shaped, else `generic`), handled, synthetic,
///   isExceptionGroup and the numeric IDs only — `data` is dropped
///   entirely, along with `meta`, `description`, `helpLink`,
///   `source`.
/// - Contexts may contain only: `app` (name/version/build — the
///   permissions map dies with the rebuilt App), `device` (family,
///   model, manufacturer, archs — the installation ID's device copy
///   dies here), `os` (name/version), and `runtime` only when its
///   name is exactly `Dart` or `Flutter` with a version-shaped
///   version (the Dart Condition 6 rule; a Java/native runtime entry
///   is dropped whole). The trace context is not copied: the Dart
///   scrub's Contexts rebuild does not copy it either, and §1.5
///   permits it only, never requires it. Every other context key is
///   dropped.
/// - Tags are filtered to {`release`, `environment`} — the plugin
///   callback's `event.origin` / `event.environment` tags and the
///   processor's `isSideLoaded` / `installerStore` tags die here.
///
/// TOTAL FUNCTION (§1.3): every step is defensive against null /
/// absent / malformed fields, the whole scrub is wrapped so it can
/// never throw (a throwing beforeSend makes `executeBeforeSend`
/// DROP the event — the disqualifying opposite failure), and it
/// never returns null (fatal native events must still arrive,
/// scrubbed).
///
/// Sessions are expressly out of this scrub's reach (§1.5): it does
/// not touch session envelope items (they never pass through
/// beforeSend) and does not read or write `options.distinctId`.
object NativeCrashScrub {

    /// Static replacement for every exception value (§1.5) —
    /// character for character the Dart marker in
    /// crash_reporting.dart (`CrashReporting.scrubbedExceptionValue`).
    const val SCRUBBED_EXCEPTION_VALUE =
        "[scrubbed: exception value withheld — type and stack trace only]"

    const val SCRUBBED_EXCEPTION_TYPE = "ScrubbedExceptionType"

    // Same identifier rule as Dart sanitizeExceptionType.
    private val IDENTIFIER_REGEX = Regex("^[A-Za-z_][A-Za-z0-9_.\$]*$")

    // Same rule as Dart _scrubMechanism's type check (adds '-').
    private val MECHANISM_TYPE_REGEX = Regex("^[A-Za-z_][A-Za-z0-9_.\$-]*$")

    // Same shape rule as Dart sanitizeRuntimeVersion.
    private val RUNTIME_VERSION_REGEX = Regex(
        "^\\d+(?:\\.\\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?(?: \\([A-Za-z]+\\))?\$"
    )

    private val ALLOWED_RUNTIME_NAMES = setOf("Dart", "Flutter")
    private val ALLOWED_TAG_KEYS = setOf("release", "environment")

    /** The beforeSend entry point. Never throws, never returns null. */
    fun scrub(event: SentryEvent): SentryEvent {
        try {
            scrubInPlace(event)
        } catch (_: Throwable) {
            // Total function: a defect in any single field's handling
            // must neither drop the event (throw) nor be reachable as
            // a crash of the capturing thread. The per-field steps
            // below are each null-defensive, so reaching this catch
            // means something structurally unexpected; the event is
            // returned as-is rather than not at all (§1.3).
        }
        return event
    }

    private fun scrubInPlace(event: SentryEvent) {
        // ── Top-level removals (§1.5: absent, no exceptions) ──
        event.setUser(null)
        event.setRequest(null)
        event.setBreadcrumbs(null)
        event.setExtras(null)
        event.setModules(null)
        event.setMessage(null)
        event.setServerName(null)
        event.setFingerprints(null)
        event.setThreads(null)
        event.setTransaction(null)
        event.setLogger(null)
        event.setUnknown(null)

        // ── Tags: allowlist keys only ──
        val oldTags = try {
            event.getTags()
        } catch (_: Throwable) {
            null
        }
        val tags = LinkedHashMap<String, String>()
        if (oldTags != null) {
            for (key in ALLOWED_TAG_KEYS) {
                val value = oldTags[key]
                if (value != null) tags[key] = value
            }
        }
        event.setTags(tags)

        scrubContexts(event)
        scrubExceptions(event)
        // eventId, timestamp, platform, level, release, dist,
        // environment and the sdk block are permitted as-is (§1.5)
        // and are deliberately untouched.
    }

    private fun scrubContexts(event: SentryEvent) {
        val contexts = event.getContexts()

        val oldApp = try {
            contexts.getApp()
        } catch (_: Throwable) {
            null
        }
        val oldDevice = try {
            contexts.getDevice()
        } catch (_: Throwable) {
            null
        }
        val oldOs = try {
            contexts.getOperatingSystem()
        } catch (_: Throwable) {
            null
        }
        val oldRuntime = try {
            contexts.getRuntime()
        } catch (_: Throwable) {
            null
        }

        // Drop EVERY context key (gpu, browser, response, replay,
        // custom keys, trace, …), then re-add only the allowlist.
        contexts.clear()

        if (oldApp != null) {
            val app = App()
            app.setAppName(oldApp.getAppName())
            app.setAppVersion(oldApp.getAppVersion())
            app.setAppBuild(oldApp.getAppBuild())
            // permissions map, app identifier, start time,
            // in-foreground, view names, split-APK data: not copied.
            contexts.setApp(app)
        }
        if (oldDevice != null) {
            val device = Device()
            device.setFamily(oldDevice.getFamily())
            device.setModel(oldDevice.getModel())
            device.setManufacturer(oldDevice.getManufacturer())
            device.setArchs(oldDevice.getArchs())
            // id (the installation ID's second copy), name, brand,
            // model_id, chipset, orientation, simulator, screen,
            // memory, storage, battery, timezone, locale, boot_time,
            // processor and connection fields: not copied.
            contexts.setDevice(device)
        }
        if (oldOs != null) {
            val os = OperatingSystem()
            os.setName(oldOs.getName())
            os.setVersion(oldOs.getVersion())
            // build, kernel version, rooted, raw description: absent.
            contexts.setOperatingSystem(os)
        }
        if (oldRuntime != null && ALLOWED_RUNTIME_NAMES.contains(oldRuntime.getName())) {
            val runtime = SentryRuntime()
            runtime.setName(oldRuntime.getName())
            runtime.setVersion(sanitizeRuntimeVersion(oldRuntime.getVersion()))
            contexts.setRuntime(runtime)
        }
        // A Java/native runtime entry fails the name check above and
        // is dropped whole (§1.5 runtime row, fail-closed).
    }

    private fun scrubExceptions(event: SentryEvent) {
        val old = try {
            event.getExceptions()
        } catch (_: Throwable) {
            null
        } ?: return
        val rebuilt = ArrayList<SentryException>(old.size)
        for (e in old) {
            if (e == null) continue
            val ex = SentryException()
            ex.setType(sanitizeExceptionType(e.getType()))
            ex.setValue(SCRUBBED_EXCEPTION_VALUE)
            ex.setModule(e.getModule())
            ex.setThreadId(e.getThreadId())
            val trace = e.getStacktrace()
            if (trace != null) {
                ex.setStacktrace(scrubStackTrace(trace))
            }
            val mechanism = e.getMechanism()
            if (mechanism != null) {
                ex.setMechanism(scrubMechanism(mechanism))
            }
            // unknown: not copied.
            rebuilt.add(ex)
        }
        event.setExceptions(rebuilt)
    }

    private fun scrubStackTrace(trace: SentryStackTrace): SentryStackTrace {
        val out = SentryStackTrace()
        val oldFrames = try {
            trace.getFrames()
        } catch (_: Throwable) {
            null
        }
        if (oldFrames != null) {
            val frames = ArrayList<SentryStackFrame>(oldFrames.size)
            for (f in oldFrames) {
                if (f == null) continue
                val frame = SentryStackFrame()
                frame.setModule(f.getModule())
                frame.setFunction(f.getFunction())
                frame.setFilename(f.getFilename())
                frame.setLineno(f.getLineno())
                frame.setColno(f.getColno())
                frame.setInApp(f.isInApp())
                // absPath, context lines, pre/post context, vars,
                // symbol/instruction addresses, lock reason: absent.
                frames.add(frame)
            }
            out.setFrames(frames)
        }
        // registers and snapshot: not copied.
        return out
    }

    private fun scrubMechanism(mechanism: Mechanism): Mechanism {
        val out = Mechanism()
        val type = mechanism.getType()
        out.setType(
            if (type != null &&
                type.length <= 128 &&
                MECHANISM_TYPE_REGEX.matches(type)
            ) {
                type
            } else {
                "generic"
            }
        )
        out.setHandled(mechanism.isHandled())
        out.setSynthetic(mechanism.getSynthetic())
        out.setExceptionGroup(mechanism.isExceptionGroup())
        out.setExceptionId(mechanism.getExceptionId())
        out.setParentId(mechanism.getParentId())
        // data dropped ENTIRELY (not filtered key by key); meta,
        // description, helpLink, source, unknown: absent.
        return out
    }

    /** Same rule as Dart `CrashReporting.sanitizeExceptionType`. */
    fun sanitizeExceptionType(type: String?): String {
        return if (type != null &&
            type.length <= 128 &&
            IDENTIFIER_REGEX.matches(type)
        ) {
            type
        } else {
            SCRUBBED_EXCEPTION_TYPE
        }
    }

    /** Same rule as Dart `CrashReporting.sanitizeRuntimeVersion`. */
    fun sanitizeRuntimeVersion(version: String?): String? {
        return if (version != null &&
            version.length <= 64 &&
            RUNTIME_VERSION_REGEX.matches(version)
        ) {
            version
        } else {
            null
        }
    }
}
