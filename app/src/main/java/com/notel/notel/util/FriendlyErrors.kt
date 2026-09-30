package com.notel.notel.util

import android.util.Log

/**
 * Friendly error surfaces (phase 2, Mira spec 2026-09-29).
 *
 * Single owner for mapping backend failures to user-visible copy. Every catch
 * block that can surface to UI calls [forBackendError], which logs the
 * technical detail internally (Log.e with the throwable: class + message +
 * stack) and returns template copy. Raw exception messages, status codes, and
 * stack traces never reach UI state.
 *
 * Copy rules: dash-free (no em/en dashes or hyphens), calm voice, never
 * invents facts. "Your data is safe" variants are only returned for failure
 * kinds where local data is verifiably retained.
 */
object FriendlyErrors {

    /** Template kind. UNKNOWN falls back to the Template 2 (load) copy per Mira's spec. */
    enum class Kind { SAVE, LOAD, NETWORK, EXPORT, AUTH, UNKNOWN }

    /** Internal log sink. Swapped for a no-op in unit tests (android.util.Log is unavailable on JVM). */
    internal var logError: (tag: String, message: String, throwable: Throwable?) -> Unit =
        { tag, message, throwable -> Log.e(tag, message, throwable) }

    data class FriendlyError(
        val headline: String,
        val explanation: String,
        val actionLabel: String?,
        val kind: Kind
    ) {
        /** Single-string form for banners, toasts, and inline error text. */
        val banner: String get() = "$headline. $explanation"
    }

    /**
     * Single internal log path for every surfaced failure. [forBackendError]
     * is the one public resolver for template copy; the inline one-liner
     * helpers below (Mira spec section 4) keep their own small copy but share
     * this exact log path, so every catch that surfaces to UI logs the
     * technical detail (class + message + stack) internally exactly once.
     */
    private fun logFailure(tag: String, context: String, throwable: Throwable?) {
        val causeName = throwable?.javaClass?.simpleName ?: "null"
        logError(tag, "$context: $causeName", throwable)
    }

    /**
     * Resolve a backend failure to friendly template copy and log the technical
     * detail internally. Call from every catch block that can surface to UI.
     *
     * @param tag log tag (the calling screen / ViewModel name)
     * @param throwable the caught failure; logged with class + message + stack, never shown
     * @param kind which template applies; UNKNOWN falls back to the load-failure copy
     */
    fun forBackendError(tag: String, throwable: Throwable?, kind: Kind = Kind.UNKNOWN): FriendlyError {
        logFailure(tag, "Backend failure [$kind]", throwable)
        return when (kind) {
            Kind.SAVE -> FriendlyError(
                headline = "Could not save your entry",
                explanation = "Something went wrong while saving. Your entry is still on this screen, so nothing is lost.",
                actionLabel = "Try again",
                kind = kind
            )
            Kind.LOAD, Kind.UNKNOWN -> FriendlyError(
                headline = "Could not load your data",
                explanation = "We could not pull your latest entries. Anything already saved is still here. Check your connection and try again.",
                actionLabel = "Try again",
                kind = kind
            )
            Kind.NETWORK -> FriendlyError(
                headline = "You are offline",
                explanation = "This needs an internet connection. Reconnect and try again. Your data is safe on this device.",
                actionLabel = "Try again",
                kind = kind
            )
            Kind.EXPORT -> FriendlyError(
                headline = "Could not create your PDF",
                explanation = "The report could not be generated. Your data is safe and nothing was deleted.",
                actionLabel = "Try again",
                kind = kind
            )
            Kind.AUTH -> FriendlyError(
                headline = "Could not sign you in",
                explanation = "We could not reach the sign in service. Check your connection and try again.",
                actionLabel = "Try again",
                kind = kind
            )
        }
    }

    // ── Inline one-liners (Mira spec §4, for failures too small for a template) ──

    /** Save one-liner: "Could not save. Your entry is kept here." */
    fun saveOneLiner(tag: String, throwable: Throwable?): String {
        logFailure(tag, "Save failure", throwable)
        return "Could not save. Your entry is kept here."
    }

    /** Sync one-liner (no retry action; the on-screen sync button is the retry). */
    fun syncOneLiner(tag: String, throwable: Throwable?): String {
        logFailure(tag, "Sync failure", throwable)
        return "Sync did not finish. Try again when you are back online."
    }

    /** Export one-liner. */
    fun exportOneLiner(tag: String, throwable: Throwable?): String {
        logFailure(tag, "Export failure", throwable)
        return "Export failed. Your data is unchanged."
    }

    // ── QuickLog save failure (Otto-confirmed copy: "Your text is still here.") ──

    fun quickLogSaveFailure(tag: String, throwable: Throwable?): String {
        logFailure(tag, "QuickLog save failure", throwable)
        return "Could not save your entry. Your text is still here, so nothing is lost."
    }

    // ── Coach first-person failures (Otto-confirmed coach voice) ──

    fun coachSendFailure(tag: String, throwable: Throwable?): String {
        logFailure(tag, "Coach send failure", throwable)
        return "I could not send that. My connection dropped. Want me to try again?"
    }

    fun coachFileReadFailure(tag: String, throwable: Throwable?): String {
        logFailure(tag, "Coach file read failure", throwable)
        return "I could not read that file. Could you try sending it again?"
    }

    fun coachCalendarAddFailure(tag: String, throwable: Throwable?): String {
        logFailure(tag, "Coach calendar add failure", throwable)
        return "I could not add that to your calendar. Want me to try again?"
    }

    fun coachCalendarDeleteFailure(tag: String, throwable: Throwable?): String {
        logFailure(tag, "Coach calendar delete failure", throwable)
        return "I could not remove that from your calendar. Want me to try again?"
    }

    // ── CSV import failure (Blood Pressure screen dialog) ──

    fun csvImportFailure(tag: String, throwable: Throwable?): String {
        logFailure(tag, "CSV import failure", throwable)
        return "Could not import your CSV. Your existing data is unchanged."
    }

    // ── Blood pressure reading delete failure ──

    fun bpDeleteFailure(tag: String, throwable: Throwable?): String {
        logFailure(tag, "BP delete failure", throwable)
        return "Could not delete your reading. Please try again."
    }
}
