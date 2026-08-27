package com.notel.notel.data.repository

import com.notel.notel.data.repository.DailySnapshotPoint
import com.notel.notel.data.repository.WeeklySnapshotMetricData
import com.notel.notel.ui.viewmodel.WeeklySnapshotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class WeeklySnapshotUnitTests {

    @Test
    fun testDailySnapshotPointMissingValueDifference() {
        val pointMissing = DailySnapshotPoint(dateStr = "2026-08-27", dayLabel = "8/27", value = null)
        val pointZero = DailySnapshotPoint(dateStr = "2026-08-27", dayLabel = "8/27", value = 0f)

        assertNull("Missing value should be null", pointMissing.value)
        assertEquals("Zero value should be exactly 0f", 0f, pointZero.value)
    }

    @Test
    fun testWeeklySnapshotMetricDataProperties() {
        val points = listOf(
            DailySnapshotPoint("2026-08-26", "8/26", 7.5f),
            DailySnapshotPoint("2026-08-27", "8/27", 8.0f)
        )
        val metricData = WeeklySnapshotMetricData(
            metricName = "Sleep Hours",
            unit = "h",
            points = points,
            averageOrTotalText = "7-Day Avg: 7h 45m",
            isAvailable = true
        )

        assertEquals("Sleep Hours", metricData.metricName)
        assertEquals("h", metricData.unit)
        assertEquals(2, metricData.points.size)
        assertTrue(metricData.isAvailable)
    }

    @Test
    fun testWeeklySnapshotStateTransitions() {
        val loadingState = WeeklySnapshotState.Loading
        assertTrue(loadingState is WeeklySnapshotState.Loading)

        val points = listOf(DailySnapshotPoint("2026-08-27", "8/27", 100f))
        val metricData = WeeklySnapshotMetricData("Medication Adherence", "%", points, "7-Day Adherence: 100%")
        val readyState = WeeklySnapshotState.Ready(
            metricData = metricData,
            availableMetrics = listOf("Sleep Hours", "Medication Adherence"),
            isRefreshing = false
        )

        assertTrue(readyState is WeeklySnapshotState.Ready)
        assertEquals("Medication Adherence", readyState.metricData.metricName)
        assertFalse(readyState.isRefreshing)
    }
}
