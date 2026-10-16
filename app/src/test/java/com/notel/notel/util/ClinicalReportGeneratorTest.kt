package com.notel.notel.util

import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.model.*
import org.junit.Assert.*
import org.junit.Test

class ClinicalReportGeneratorTest {

    @Test
    fun snapshot_hasAnyData_returnsFalse_whenEmpty() {
        val emptySnapshot = ClinicalReportData(
            range = ClinicalReportRange(ClinicalReportRangeType.LAST_30_DAYS, 0L, 1000L)
        )
        assertFalse(emptySnapshot.hasAnyData)
    }

    @Test
    fun snapshot_hasAnyData_returnsTrue_whenLogEntriesPresent() {
        val snapshot = ClinicalReportData(
            range = ClinicalReportRange(ClinicalReportRangeType.LAST_30_DAYS, 0L, 1000L),
            logEntries = listOf(LogEntry(id = 1, categoryId = 1, body = "Patient note", chips = "", manualText = "", timestamp = 500L))
        )
        assertTrue(snapshot.hasAnyData)
    }

    @Test
    fun snapshot_hasAnyData_returnsTrue_whenHealthMetricsPresent() {
        val snapshot = ClinicalReportData(
            range = ClinicalReportRange(ClinicalReportRangeType.FULL, 0L, 1000L),
            heartRateSeries = listOf("2026-09-22" to 72)
        )
        assertTrue(snapshot.hasAnyData)
    }

    @Test
    fun clinicalReportRange_durationDays_calculatesCorrectly() {
        val range30 = ClinicalReportRange(
            type = ClinicalReportRangeType.LAST_30_DAYS,
            startEpochMs = 1_000_000L,
            endEpochMs = 1_000_000L + (30L * 24 * 60 * 60 * 1000L)
        )
        assertEquals(30, range30.durationDays)
    }

    @Test
    fun heartRateCoveredDates_reflectActualSeriesNotNominalRange() {
        // Nominal range is 180 days, but the series only holds 14 days: the
        // covered dates must say so (the Oct 16, 2026 honest-window fix).
        val start = System.currentTimeMillis() - (180L * 24 * 60 * 60 * 1000)
        val snapshot = ClinicalReportData(
            range = ClinicalReportRange(ClinicalReportRangeType.FULL, start, start + (180L * 24 * 60 * 60 * 1000)),
            heartRateSeries = listOf(
                "2026-10-16" to 77,
                "2026-10-03" to 74,
                "2026-10-10" to 76
            )
        )
        assertEquals("2026-10-03", snapshot.heartRateCoveredStartDate)
        assertEquals("2026-10-16", snapshot.heartRateCoveredEndDate)
    }

    @Test
    fun heartRateCoveredDates_ignoreZeroValues_asFailedReads() {
        val snapshot = ClinicalReportData(
            range = ClinicalReportRange(ClinicalReportRangeType.FULL, 0L, 1000L),
            heartRateSeries = listOf(
                "2026-04-19" to 0, // failed read — must not extend coverage
                "2026-10-03" to 74,
                "2026-10-16" to 77
            )
        )
        assertEquals("2026-10-03", snapshot.heartRateCoveredStartDate)
        assertEquals("2026-10-16", snapshot.heartRateCoveredEndDate)
    }

    @Test
    fun hrSpikesCoveredDates_comeFromSpikeSummaries() {
        val summary = { date: String ->
            com.notel.notel.data.healthconnect.DailyHeartRateSummary(
                date = date, avg = 0, max = 0, min = 0, baseline = 0,
                spikeCount = 4, maxDelta = 0, totalReadings = 0
            )
        }
        val snapshot = ClinicalReportData(
            range = ClinicalReportRange(ClinicalReportRangeType.FULL, 0L, 1000L),
            heartRateSpikes = listOf(summary("2026-09-30"), summary("2026-04-28"), summary("2026-10-16"))
        )
        assertEquals("2026-04-28", snapshot.hrSpikesCoveredStartDate)
        assertEquals("2026-10-16", snapshot.hrSpikesCoveredEndDate)
    }

    @Test
    fun coveredDates_areNull_whenNoHeartRateData() {
        val snapshot = ClinicalReportData(
            range = ClinicalReportRange(ClinicalReportRangeType.FULL, 0L, 1000L)
        )
        assertNull(snapshot.heartRateCoveredStartDate)
        assertNull(snapshot.heartRateCoveredEndDate)
        assertNull(snapshot.hrSpikesCoveredStartDate)
        assertNull(snapshot.hrSpikesCoveredEndDate)
    }

    @Test
    fun sectionMetadata_tracksPartialFailuresCorrectly() {
        val metadata = mapOf(
            "sleep" to SectionMetadata("sleep", DataSourceStatus.SUCCESS, recordCount = 30),
            "heartRate" to SectionMetadata("heartRate", DataSourceStatus.TIMED_OUT, recordCount = 0, message = "Timed out")
        )
        val snapshot = ClinicalReportData(
            range = ClinicalReportRange(ClinicalReportRangeType.LAST_30_DAYS, 0L, 1000L),
            sleepSeries = listOf("2026-09-22" to 480),
            sectionMetadata = metadata
        )
        
        assertEquals(DataSourceStatus.SUCCESS, snapshot.sectionMetadata["sleep"]?.status)
        assertEquals(DataSourceStatus.TIMED_OUT, snapshot.sectionMetadata["heartRate"]?.status)
        assertTrue(snapshot.hasAnyData)
    }
}
