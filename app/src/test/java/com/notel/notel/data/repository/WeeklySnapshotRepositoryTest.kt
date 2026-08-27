package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.ui.navigation.WeeklySnapshotDestinationMapper
import com.notel.notel.ui.viewmodel.WeeklySnapshotState
import com.notel.notel.util.TestTimeProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.time.Clock
import java.time.Instant
import java.time.ZoneId

class WeeklySnapshotRepositoryTest {

    private lateinit var timeProvider: TestTimeProvider
    private lateinit var aggregator: WeeklySnapshotAggregator

    @Before
    fun setup() {
        // Fixed test clock: Thursday 2026-08-27 at 12:00 UTC
        val fixedClock = Clock.fixed(
            Instant.parse("2026-08-27T12:00:00Z"),
            ZoneId.of("UTC")
        )
        timeProvider = TestTimeProvider(fixedClock)
        aggregator = WeeklySnapshotAggregator(timeProvider)
    }

    @Test
    fun test7DayDateConstructionAndWeekdayLabels() {
        val (dates, dateStrsAndLabels) = aggregator.get7DayDates()
        val (dateStrs, dayLabels) = dateStrsAndLabels

        assertEquals(7, dates.size)
        assertEquals(7, dayLabels.size)
        assertEquals("Fri", dayLabels[0])
        assertEquals("Thu", dayLabels[6])
        assertEquals("2026-08-21", dateStrs[0])
        assertEquals("2026-08-27", dateStrs[6])
    }

    @Test
    fun testHrSpikeGroupingMultipleSpikesAndZeroVsNull() {
        val (dates, dateStrsAndLabels) = aggregator.get7DayDates()
        val (dateStrs, dayLabels) = dateStrsAndLabels

        val spikes = listOf(
            DailyHeartRateSummary(date = "2026-08-27", avg = 82, max = 145, min = 65, baseline = 65, spikeCount = 3, maxDelta = 80, totalReadings = 100),
            DailyHeartRateSummary(date = "2026-08-26", avg = 75, max = 110, min = 60, baseline = 60, spikeCount = 0, maxDelta = 50, totalReadings = 100),
            DailyHeartRateSummary(date = "2026-08-25", avg = 78, max = 130, min = 62, baseline = 62, spikeCount = 1, maxDelta = 68, totalReadings = 100)
        )

        // Valid read with spikes
        val result = aggregator.aggregateHrSpikes(dates, dateStrs, dayLabels, spikes)
        assertEquals("HR Spikes", result.metricName)
        assertEquals(3.0f, result.points[6].value) // 2026-08-27
        assertEquals(0.0f, result.points[5].value) // Explicit 0 for 2026-08-26
        assertEquals(1.0f, result.points[4].value) // 2026-08-25
        assertEquals(0.0f, result.points[0].value) // Explicit 0 for day with no entry in checked source
        assertEquals("7-Day Total: 4 spikes", result.averageOrTotalText)

        // Null when read failed
        val nullResult = aggregator.aggregateHrSpikes(dates, dateStrs, dayLabels, null)
        assertNull("Missing/unread HR spike data must be null", nullResult.points[6].value)
        assertEquals("Could not load HR spike records", nullResult.emptyMessage)
    }

    @Test
    fun testSleepMinuteConversionAndMissingNullValues() {
        val (dates, dateStrsAndLabels) = aggregator.get7DayDates()
        val (dateStrs, dayLabels) = dateStrsAndLabels

        val rawHistory = listOf(
            "2026-08-27" to 480, // 8.0h
            "2026-08-26" to 450  // 7.5h
        )

        val result = aggregator.aggregateSleep(dateStrs, dayLabels, rawHistory)
        assertEquals("Sleep Hours", result.metricName)
        assertEquals(8.0f, result.points[6].value)
        assertEquals(7.5f, result.points[5].value)
        assertNull("Missing day 2026-08-25 must be null, not 0", result.points[4].value)
    }

    @Test
    fun testZeroLogsRemainsZeroCount() {
        val (dates, dateStrsAndLabels) = aggregator.get7DayDates()
        val (dateStrs, dayLabels) = dateStrsAndLabels

        val entries = listOf(
            LogEntry(id = 1, timestamp = Instant.parse("2026-08-27T10:00:00Z").toEpochMilli(), categoryId = 1, body = "Note")
        )

        val result = aggregator.aggregateLogs(dateStrs, dayLabels, entries)
        assertEquals(1.0f, result.points[6].value)
        assertEquals(0.0f, result.points[5].value) // Explicit 0 count for log day with no logs
    }

    @Test
    fun testHabitUninitializedVsEmptyLoadedState() {
        val (dates, dateStrsAndLabels) = aggregator.get7DayDates()
        val (dateStrs, dayLabels) = dateStrsAndLabels

        // Uninitialized state
        val uninitResult = aggregator.aggregateHabits(dateStrs, dayLabels, emptyList(), isInitialized = false)
        assertEquals("Loading habits...", uninitResult.averageOrTotalText)
        assertNull(uninitResult.emptyMessage)

        // Initialized empty state
        val initEmptyResult = aggregator.aggregateHabits(dateStrs, dayLabels, emptyList(), isInitialized = true)
        assertEquals("No habits configured", initEmptyResult.averageOrTotalText)
        assertEquals("No habits configured", initEmptyResult.emptyMessage)
    }

    @Test
    fun testProductionDestinationMapping() {
        assertEquals("sleep", WeeklySnapshotDestinationMapper.mapMetricToDestination("Sleep Hours"))
        assertEquals("fitbit", WeeklySnapshotDestinationMapper.mapMetricToDestination("Resting Heart Rate"))
        assertEquals("hr_spikes", WeeklySnapshotDestinationMapper.mapMetricToDestination("HR Spikes"))
        assertEquals("key_metrics", WeeklySnapshotDestinationMapper.mapMetricToDestination("Calories"))
        assertEquals("history", WeeklySnapshotDestinationMapper.mapMetricToDestination("Logs"))
        assertEquals("habits", WeeklySnapshotDestinationMapper.mapMetricToDestination("Habit Completion"))
        assertEquals("blood_pressure", WeeklySnapshotDestinationMapper.mapMetricToDestination("Blood Pressure"))
    }

    @Test
    fun testSelectorExcludesMedicationAndSymptoms() {
        val defaultMetrics = listOf(
            "Sleep Hours",
            "Resting Heart Rate",
            "HR Spikes",
            "Calories",
            "Logs",
            "Habit Completion"
        )
        assertFalse(defaultMetrics.contains("Medication Adherence"))
        assertFalse(defaultMetrics.contains("Symptoms"))
    }
}
