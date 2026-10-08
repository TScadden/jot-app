package com.notel.notel.data.model

import org.junit.Assert.*
import org.junit.Test

class ReportRangeTest {

    private val now = 1_757_000_000_000L // fixed "now" for determinism
    private val dayMs = 24 * 60 * 60 * 1000L

    @Test
    fun last30Days_resolvesToRolling30DayWindow() {
        val range = ReportRange.Last30Days.toClinicalReportRange(now)
        assertEquals(ClinicalReportRangeType.LAST_30_DAYS, range.type)
        assertEquals(now - 30L * dayMs, range.startEpochMs)
        assertEquals(now, range.endEpochMs)
        assertEquals(30, range.durationDays)
    }

    @Test
    fun allTime_resolvesToUncappedZeroStart() {
        val range = ReportRange.AllTime.toClinicalReportRange(now)
        assertEquals(ClinicalReportRangeType.FULL, range.type)
        assertEquals(0L, range.startEpochMs)
        assertEquals(now, range.endEpochMs)
    }

    @Test
    fun sinceLastMeeting_usesMeetingDateAsStart() {
        val meeting = now - 45L * dayMs
        val range = ReportRange.SinceLastMeeting(meeting).toClinicalReportRange(now)
        assertEquals(ClinicalReportRangeType.SINCE_LAST_MEETING, range.type)
        assertEquals(meeting, range.startEpochMs)
        assertEquals(now, range.endEpochMs)
        assertEquals(45, range.durationDays)
    }

    @Test
    fun sinceLastMeeting_futureMeetingDate_coercedToNow() {
        val range = ReportRange.SinceLastMeeting(now + 5L * dayMs).toClinicalReportRange(now)
        assertEquals(now, range.startEpochMs)
        assertEquals(now, range.endEpochMs)
        assertEquals(1, range.durationDays) // coercedAtLeast(1), never zero/negative
    }

    @Test
    fun custom_normalizesSwappedBounds() {
        val start = now - 10L * dayMs
        val end = now - 3L * dayMs
        val range = ReportRange.Custom(end, start).toClinicalReportRange(now)
        assertEquals(ClinicalReportRangeType.CUSTOM, range.type)
        assertEquals(start, range.startEpochMs)
        assertEquals(end, range.endEpochMs)
    }

    @Test
    fun custom_futureEnd_coercedToNow() {
        val start = now - 10L * dayMs
        val range = ReportRange.Custom(start, now + 9L * dayMs).toClinicalReportRange(now)
        assertEquals(start, range.startEpochMs)
        assertEquals(now, range.endEpochMs)
    }

    @Test
    fun prefsKey_roundTripsThroughFromPrefsKey() {
        assertEquals(ReportRange.Last30Days, ReportRange.fromPrefsKey(ReportRange.Last30Days.prefsKey))
        assertEquals(ReportRange.AllTime, ReportRange.fromPrefsKey(ReportRange.AllTime.prefsKey))
        assertEquals(ReportRange.Last30Days, ReportRange.fromPrefsKey(null))
        assertEquals(ReportRange.Last30Days, ReportRange.fromPrefsKey("bogus"))
    }

    @Test
    fun clinicalRange_carriesTimezoneId() {
        val range = ReportRange.Last30Days.toClinicalReportRange(now, "America/Denver")
        assertEquals("America/Denver", range.timezoneId)
    }
}
