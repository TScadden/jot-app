package com.notel.notel.util

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Phase 2 friendly-error tests: template copy matches Mira's spec, all copy is
 * dash-free (no em dash, en dash, or hyphen), and raw exception details never
 * reach the returned strings.
 */
class FriendlyErrorsTest {

    private val logged = mutableListOf<Triple<String, String, Throwable?>>()

    @Before
    fun setUp() {
        logged.clear()
        FriendlyErrors.logError = { tag, message, throwable ->
            logged.add(Triple(tag, message, throwable))
        }
    }

    @After
    fun tearDown() {
        // Restore the real android.util.Log sink
        FriendlyErrors.logError = { tag, message, throwable ->
            android.util.Log.e(tag, message, throwable)
        }
    }

    private fun assertDashFree(vararg texts: String) {
        for (text in texts) {
            assertFalse("em dash found in: $text", text.contains("—"))
            assertFalse("en dash found in: $text", text.contains("–"))
            assertFalse("hyphen found in: $text", text.contains("-"))
        }
    }

    private fun assertNoLeak(copy: String, throwable: Throwable) {
        val secret = "SECRET_BACKEND_DETAIL_9f3"
        assertFalse("raw backend detail leaked into UI copy: $copy", copy.contains(secret))
        assertFalse("exception class leaked into UI copy: $copy", copy.contains(throwable.javaClass.simpleName))
    }

    @Test
    fun saveTemplate_matchesMiraSpec() {
        val err = FriendlyErrors.forBackendError("T", RuntimeException("SECRET_BACKEND_DETAIL_9f3"), FriendlyErrors.Kind.SAVE)
        assertEquals("Could not save your entry", err.headline)
        assertEquals(
            "Something went wrong while saving. Your entry is still on this screen, so nothing is lost.",
            err.explanation
        )
        assertDashFree(err.headline, err.explanation, err.banner)
        assertNoLeak(err.banner, RuntimeException("SECRET_BACKEND_DETAIL_9f3"))
    }

    @Test
    fun loadTemplate_matchesMiraSpec_andIsUnknownFallback() {
        val load = FriendlyErrors.forBackendError("T", RuntimeException("x"), FriendlyErrors.Kind.LOAD)
        assertEquals("Could not load your data", load.headline)
        assertEquals(
            "We could not pull your latest entries. Anything already saved is still here. Check your connection and try again.",
            load.explanation
        )
        val unknown = FriendlyErrors.forBackendError("T", RuntimeException("x"), FriendlyErrors.Kind.UNKNOWN)
        assertEquals(load.headline, unknown.headline)
        assertEquals(load.explanation, unknown.explanation)
        assertDashFree(load.headline, load.explanation, load.banner)
    }

    @Test
    fun networkTemplate_matchesMiraSpec() {
        val err = FriendlyErrors.forBackendError("T", null, FriendlyErrors.Kind.NETWORK)
        assertEquals("You are offline", err.headline)
        assertEquals(
            "This needs an internet connection. Reconnect and try again. Your data is safe on this device.",
            err.explanation
        )
        assertDashFree(err.headline, err.explanation)
    }

    @Test
    fun exportTemplate_matchesMiraSpec() {
        val err = FriendlyErrors.forBackendError("T", RuntimeException("x"), FriendlyErrors.Kind.EXPORT)
        assertEquals("Could not create your PDF", err.headline)
        assertEquals(
            "The report could not be generated. Your data is safe and nothing was deleted.",
            err.explanation
        )
        assertDashFree(err.headline, err.explanation)
    }

    @Test
    fun authTemplate_isGeneric() {
        val err = FriendlyErrors.forBackendError("T", RuntimeException("statusCode=10"), FriendlyErrors.Kind.AUTH)
        assertEquals("Could not sign you in", err.headline)
        assertFalse(err.banner.contains("10"))
        assertDashFree(err.headline, err.explanation)
    }

    @Test
    fun resolver_logsTechnicalDetailInternally() {
        val boom = IllegalStateException("SECRET_BACKEND_DETAIL_9f3")
        FriendlyErrors.forBackendError("MyTag", boom, FriendlyErrors.Kind.SAVE)
        assertEquals(1, logged.size)
        val (tag, message, throwable) = logged[0]
        assertEquals("MyTag", tag)
        assertTrue(message.contains("IllegalStateException"))
        assertSame(boom, throwable)
    }

    @Test
    fun quickLogSaveFailure_usesOttoConfirmedCopy() {
        val copy = FriendlyErrors.quickLogSaveFailure("T", RuntimeException("x"))
        assertEquals("Could not save your entry. Your text is still here, so nothing is lost.", copy)
        assertDashFree(copy)
    }

    @Test
    fun coachFailures_useFirstPersonCoachVoice() {
        assertEquals(
            "I could not send that. My connection dropped. Want me to try again?",
            FriendlyErrors.coachSendFailure("T", RuntimeException("x"))
        )
        assertEquals(
            "I could not read that file. Could you try sending it again?",
            FriendlyErrors.coachFileReadFailure("T", RuntimeException("x"))
        )
        assertEquals(
            "I could not add that to your calendar. Want me to try again?",
            FriendlyErrors.coachCalendarAddFailure("T", RuntimeException("x"))
        )
        assertEquals(
            "I could not remove that from your calendar. Want me to try again?",
            FriendlyErrors.coachCalendarDeleteFailure("T", RuntimeException("x"))
        )
        assertDashFree(
            FriendlyErrors.coachSendFailure("T", null),
            FriendlyErrors.coachFileReadFailure("T", null),
            FriendlyErrors.coachCalendarAddFailure("T", null),
            FriendlyErrors.coachCalendarDeleteFailure("T", null)
        )
    }

    @Test
    fun csvImportFailure_preservesExistingDataPromise() {
        val copy = FriendlyErrors.csvImportFailure("T", RuntimeException("x"))
        assertEquals("Could not import your CSV. Your existing data is unchanged.", copy)
        assertDashFree(copy)
    }

    @Test
    fun oneLiners_areDashFree() {
        assertDashFree(
            FriendlyErrors.saveOneLiner("T", null),
            FriendlyErrors.syncOneLiner("T", null),
            FriendlyErrors.exportOneLiner("T", null),
            FriendlyErrors.bpDeleteFailure("T", null)
        )
    }

    @Test
    fun heartRateNotificationCopy_isDashFree() {
        assertDashFree("Heart rate monitor disconnected. Reconnect in Settings to resume.")
    }

    @Test
    fun weeklySnapshotRetainedCopy_isDashFree() {
        assertDashFree("Your past data is safe. The latest refresh did not finish.")
    }
}
