package com.notel.notel.data.repository

import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.ScheduledDoseOccurrence
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.ui.navigation.WeeklySnapshotDestinationMapper
import com.notel.notel.util.TestTimeProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
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
    fun testSymptomsCategoryResolutionAndLegacyFallback() {
        val (dates, dateStrsAndLabels) = aggregator.get7DayDates()
        val (dateStrs, dayLabels) = dateStrsAndLabels

        // Category with nonstandard ID 99 for symptoms
        val symptomCategoryId = 99
        val entries = listOf(
            LogEntry(id = 1, timestamp = Instant.parse("2026-08-27T08:00:00Z").toEpochMilli(), categoryId = 99, body = "Custom symptom"),
            LogEntry(id = 2, timestamp = Instant.parse("2026-08-27T09:00:00Z").toEpochMilli(), categoryId = 5, body = "Unrelated cat 5"),
            LogEntry(id = 3, timestamp = Instant.parse("2026-08-27T10:00:00Z").toEpochMilli(), categoryId = 0, body = "Legacy headache note")
        )

        val result = aggregator.aggregateSymptoms(dateStrs, dayLabels, entries, symptomCategoryId)
        assertEquals(2.0f, result.points[6].value) // Should match entry 1 (cat 99) and entry 3 (cat 0 fallback), excluding cat 5
    }

    @Test
    fun testMedicationAdherenceDeduplicationAndRules() {
        val (dates, dateStrsAndLabels) = aggregator.get7DayDates()
        val (dateStrs, dayLabels) = dateStrsAndLabels

        val occurrences = listOf(
            // Past day 2026-08-26: 1 TAKEN, 1 SKIPPED -> 50%
            ScheduledDoseOccurrence(occurrenceKey = "occ_1", medicationId = 1, scheduledDate = "2026-08-26", status = "TAKEN"),
            ScheduledDoseOccurrence(occurrenceKey = "occ_2", medicationId = 2, scheduledDate = "2026-08-26", status = "SKIPPED"),
            // Duplicate key should be ignored
            ScheduledDoseOccurrence(occurrenceKey = "occ_1", medicationId = 1, scheduledDate = "2026-08-26", status = "TAKEN"),
            // Today 2026-08-27: 1 TAKEN (08:00), 1 PENDING (20:00 future excluded) -> 100%
            ScheduledDoseOccurrence(occurrenceKey = "occ_3", medicationId = 1, scheduledDate = "2026-08-27", scheduledTime = "08:00", status = "TAKEN"),
            ScheduledDoseOccurrence(occurrenceKey = "occ_4", medicationId = 1, scheduledDate = "2026-08-27", scheduledTime = "20:00", status = "PENDING")
        )

        val result = aggregator.aggregateMedication(dates, dayLabels, occurrences)
        assertEquals(50.0f, result.points[5].value)
        assertEquals(100.0f, result.points[6].value)
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
        assertEquals("key_metrics", WeeklySnapshotDestinationMapper.mapMetricToDestination("Calories"))
        assertEquals("history", WeeklySnapshotDestinationMapper.mapMetricToDestination("Logs"))
        assertEquals("history", WeeklySnapshotDestinationMapper.mapMetricToDestination("Symptoms"))
        assertEquals("medications", WeeklySnapshotDestinationMapper.mapMetricToDestination("Medication Adherence"))
        assertEquals("habits", WeeklySnapshotDestinationMapper.mapMetricToDestination("Habit Completion"))
        assertEquals("blood_pressure", WeeklySnapshotDestinationMapper.mapMetricToDestination("Blood Pressure"))
    }
}
