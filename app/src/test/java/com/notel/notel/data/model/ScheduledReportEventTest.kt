package com.notel.notel.data.model

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime

class ScheduledReportEventTest {

    private val zone = "America/Denver"
    // 2026-10-05 15:00 America/Denver (Monday).
    private val eventMs: Long = ZonedDateTime.of(
        2026, 10, 5, 15, 0, 0, 0, ZoneId.of(zone)
    ).toInstant().toEpochMilli()

    private fun event(
        prepTiming: String = "day_before",
        prepTimeOfDay: String = "09:00",
        autoPrepare: Boolean = true
    ) = ScheduledReportEvent(
        name = "Dr. visit",
        type = "doctor",
        dateTimeMs = eventMs,
        timezoneId = zone,
        prepTiming = prepTiming,
        prepTimeOfDay = prepTimeOfDay,
        autoPrepare = autoPrepare
    )

    @Test
    fun prepFireTime_dayBeforeAtChosenTime() {
        // "now" well before the event.
        val now = eventMs - 5 * 24 * 60 * 60 * 1000L
        val fireAt = prepFireTimeMs(event(), now)
        assertNotNull(fireAt)
        val zdt = ZonedDateTime.ofInstant(Instant.ofEpochMilli(fireAt!!), ZoneId.of(zone))
        assertEquals(4, zdt.dayOfMonth) // Oct 4 = day before Oct 5
        assertEquals(9, zdt.hour)
        assertEquals(0, zdt.minute)
    }

    @Test
    fun prepFireTime_dayOf() {
        val now = eventMs - 5 * 24 * 60 * 60 * 1000L
        val fireAt = prepFireTimeMs(event(prepTiming = "day_of", prepTimeOfDay = "08:30"), now)
        assertNotNull(fireAt)
        val zdt = ZonedDateTime.ofInstant(Instant.ofEpochMilli(fireAt!!), ZoneId.of(zone))
        assertEquals(5, zdt.dayOfMonth)
        assertEquals(8, zdt.hour)
        assertEquals(30, zdt.minute)
    }

    @Test
    fun prepFireTime_pastFireTimeIsNull() {
        // "now" is after the prep moment.
        val now = eventMs - 12 * 60 * 60 * 1000L
        assertNull(prepFireTimeMs(event(), now))
    }

    @Test
    fun prepFireTime_reminderOnlyIsNull() {
        val now = eventMs - 5 * 24 * 60 * 60 * 1000L
        assertNull(prepFireTimeMs(event(prepTiming = "reminder_only"), now))
        assertNull(prepFireTimeMs(event(autoPrepare = false), now))
    }

    @Test
    fun resolveEventRange_sincelastmeetingAnchorsAtMeeting() {
        val now = eventMs
        val meeting = now - 45 * 24 * 60 * 60 * 1000L
        val range = resolveEventRange(
            event().copy(rangeType = "sincelastmeeting", meetingDateMs = meeting),
            now
        )
        assertTrue(range is ReportRange.SinceLastMeeting)
        assertEquals(meeting, (range as ReportRange.SinceLastMeeting).meetingDateEpochMs)
    }

    @Test
    fun resolveEventRange_noAnchorFallsBackTo30Days() {
        val range = resolveEventRange(event().copy(rangeType = "sincelastmeeting"), eventMs)
        assertTrue(range is ReportRange.Last30Days)
    }

    @Test
    fun resolveEventRange_customUsesStoredBounds() {
        val now = eventMs
        val range = resolveEventRange(
            event().copy(rangeType = "custom", rangeStartMs = now - 10, rangeEndMs = now - 1),
            now
        )
        assertTrue(range is ReportRange.Custom)
    }

    @Test
    fun prepTimingLabel_humanReadable() {
        assertEquals("Day before at 9:00 AM", prepTimingLabel(event()))
        assertEquals("Day of at 8:30 AM", prepTimingLabel(event(prepTiming = "day_of", prepTimeOfDay = "08:30")))
        assertEquals("Reminder only", prepTimingLabel(event(prepTiming = "reminder_only")))
    }

    @Test
    fun isReminderOnly_explicitAlternative() {
        assertFalse(event().isReminderOnly)
        assertTrue(event(prepTiming = "reminder_only").isReminderOnly)
        assertTrue(event(autoPrepare = false).isReminderOnly)
    }
}
