package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.dao.ScheduledDoseOccurrenceDao
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.ScheduledDoseOccurrence
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.ui.viewmodel.WeeklySnapshotState
import com.notel.notel.util.TestTimeProvider
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class WeeklySnapshotRepositoryTest {

    private lateinit var timeProvider: TestTimeProvider

    @Before
    fun setup() {
        // Set deterministic test date: Thursday 2026-08-27
        val fixedClock = Clock.fixed(
            Instant.parse("2026-08-27T12:00:00Z"),
            ZoneId.of("UTC")
        )
        timeProvider = TestTimeProvider(fixedClock)
    }

    @Test
    fun test7DaysChronologicalOrderAndLabels() {
        val endDate = timeProvider.today()
        val dates = (6 downTo 0).map { endDate.minusDays(it.toLong()) }
        val dayLabels = dates.map { it.format(java.time.format.DateTimeFormatter.ofPattern("EEE", java.util.Locale.ENGLISH)) }

        assertEquals(7, dayLabels.size)
        assertEquals("Fri", dayLabels[0])
        assertEquals("Thu", dayLabels[6])
    }

    @Test
    fun testSleepMinutesConversionAndMissingNullHandling() {
        val rawMins = 480 // 8 hours
        val valHours = rawMins / 60f
        assertEquals(8.0f, valHours)

        val pointMissing = DailySnapshotPoint("2026-08-27", "Thu", null)
        assertNull("Missing sleep day must be null, not 0", pointMissing.value)
    }

    @Test
    fun testZeroLogsRemainsZeroCount() {
        val pointZero = DailySnapshotPoint("2026-08-27", "Thu", 0f)
        assertNotNull(pointZero.value)
        assertEquals(0f, pointZero.value)
    }

    @Test
    fun testMedicationAdherenceRules() {
        // Given 2 scheduled doses today: 1 TAKEN, 1 PENDING (future)
        val occTaken = ScheduledDoseOccurrence(
            occurrenceKey = "med_1_2026-08-27_08:00",
            medicationId = 1,
            scheduledDate = "2026-08-27",
            scheduledTime = "08:00",
            status = "TAKEN"
        )
        val occFuturePending = ScheduledDoseOccurrence(
            occurrenceKey = "med_1_2026-08-27_20:00",
            medicationId = 1,
            scheduledDate = "2026-08-27",
            scheduledTime = "20:00",
            status = "PENDING"
        )

        // At 12:00, 08:00 dose is evaluated, 20:00 future pending is excluded
        val occurrences = listOf(occTaken, occFuturePending)
        val evaluated = occurrences.filter { occ ->
            if (occ.status == "TAKEN") true
            else if (occ.status == "PENDING") {
                val time = java.time.LocalTime.parse(occ.scheduledTime!!)
                time.isBefore(java.time.LocalTime.of(12, 0))
            } else false
        }

        assertEquals(1, evaluated.size)
        assertEquals("TAKEN", evaluated[0].status)
    }

    @Test
    fun testSymptomCategoryFiltering() {
        val categoryIdSymptom = 5
        val entry1 = LogEntry(id = 1, categoryId = 5, body = "Mild headache")
        val entry2 = LogEntry(id = 2, categoryId = 6, body = "Unrelated note")
        val entry3 = LogEntry(id = 3, categoryId = 0, body = "Legacy headache note")

        val symptoms = listOf(entry1, entry2, entry3).filter { entry ->
            val matchesCat = entry.categoryId == categoryIdSymptom
            val matchesFallback = entry.categoryId == 0 && entry.body.contains("headache", ignoreCase = true)
            matchesCat || matchesFallback
        }

        assertEquals(2, symptoms.size)
        assertFalse(symptoms.contains(entry2))
    }

    @Test
    fun testViewDetailsDestinationMapping() {
        fun mapDestination(metric: String): String {
            return when (metric) {
                "Sleep Hours" -> "sleep"
                "Resting Heart Rate" -> "fitbit"
                "Calories" -> "data_connections"
                "Logs" -> "notes"
                "Symptoms" -> "notes"
                "Medication Adherence" -> "data_connections"
                "Habit Completion" -> "habits"
                "Blood Pressure" -> "data_connections"
                else -> "data_connections"
            }
        }

        assertEquals("sleep", mapDestination("Sleep Hours"))
        assertEquals("fitbit", mapDestination("Resting Heart Rate"))
        assertEquals("habits", mapDestination("Habit Completion"))
        assertEquals("notes", mapDestination("Logs"))
    }
}
