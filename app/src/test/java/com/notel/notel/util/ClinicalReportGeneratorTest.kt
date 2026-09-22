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
