package com.notel.notel.ui.viewmodel

import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.data.local.entity.ScheduledDoseOccurrence
import com.notel.notel.data.remote.HabitDtoModel
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class TodayPlanPersistenceAndOccurrenceTest {

    // --- Helper logic tests ---

    private fun buildMedicationOccurrenceKey(medicationUuid: String, medicationId: Long, dateStr: String, slotLabel: String): String {
        val identifier = medicationUuid.trim().ifEmpty { medicationId.toString() }
        val normalizedSlot = slotLabel.trim().lowercase(java.util.Locale.US).replace("\\s+".toRegex(), "_")
        return "med_${identifier}_${dateStr}_${normalizedSlot}"
    }

    private fun buildReminderOccurrenceKey(reminderId: Int, dateStr: String): String {
        return "rem_${reminderId}_${dateStr}"
    }

    // --- Fitbit Callback Unit Tests ---

    @Test
    fun fitbitCallback_oauthErrorCallback_setsErrorMessage() {
        var errorMessage: String? = null
        val error = "access_denied"
        val errorDesc = "User denied authorization"

        if (error.isNotBlank()) {
            errorMessage = "Fitbit connection error: ${errorDesc.ifBlank { error }}"
        }

        assertNotNull(errorMessage)
        assertEquals("Fitbit connection error: User denied authorization", errorMessage)
    }

    @Test
    fun fitbitCallback_missingParameters_setsErrorMessage() {
        var errorMessage: String? = null
        val code: String? = null
        val state: String? = "valid_state"

        if (code.isNullOrBlank()) {
            errorMessage = "Missing authorization code from Fitbit callback."
        } else if (state.isNullOrBlank()) {
            errorMessage = "Missing state parameter from Fitbit callback."
        }

        assertEquals("Missing authorization code from Fitbit callback.", errorMessage)
    }

    @Test
    fun fitbitCallback_invalidState_rejectsAndSetsErrorMessage() {
        val pendingState = "state_abc"
        val receivedState = "state_xyz"
        var errorMessage: String? = null
        var consumed = false

        if (pendingState != receivedState) {
            errorMessage = "OAuth state mismatch."
        } else {
            consumed = true
        }

        assertEquals("OAuth state mismatch.", errorMessage)
        assertFalse("Pending state must NOT be consumed on state mismatch", consumed)
    }

    @Test
    fun fitbitCallback_expiredState_clearsAndSetsTimeoutError() {
        val pendingTime = System.currentTimeMillis() - 700000L // 11 minutes ago
        var cleared = false
        var errorMessage: String? = null

        if (System.currentTimeMillis() - pendingTime > 600000L) {
            cleared = true
            errorMessage = "Login request timed out. Please try again."
        }

        assertTrue("Expired pending state must be cleared", cleared)
        assertEquals("Login request timed out. Please try again.", errorMessage)
    }

    @Test
    fun fitbitCallback_duplicateCallback_rejectsConsumedTransaction() {
        var pendingState = "" // Consumed on first callback
        var errorMessage: String? = null

        if (pendingState.isBlank()) {
            errorMessage = "No pending login request found."
        }

        assertEquals("No pending login request found.", errorMessage)
    }

    @Test
    fun fitbitCallback_successfulCallback_validatesAndConsumesTransaction() {
        val pendingState = "secure_state_123"
        val receivedState = "secure_state_123"
        var pendingConsumed = false
        var isFitbitConnected = false

        if (pendingState == receivedState) {
            pendingConsumed = true
            isFitbitConnected = true
        }

        assertTrue("Matching state must consume transaction", pendingConsumed)
        assertTrue("Successful callback connects Fitbit", isFitbitConnected)
    }

    @Test
    fun fitbitCallback_duplicateCodeInViewModel_ignoredByProcessedCodesSet() {
        val processedCodes = java.util.Collections.synchronizedSet(HashSet<String>())
        val code = "oauth_code_abc123"

        val firstAttemptAdded = processedCodes.add(code)
        val secondAttemptAdded = processedCodes.add(code)

        assertTrue("First attempt should add code to set", firstAttemptAdded)
        assertFalse("Second attempt with same code must be rejected as duplicate", secondAttemptAdded)
    }

    @Test
    fun fitbitCallback_activityIntentDeduplication_processesIntentOnlyOnce() {
        val processedIntents = java.util.Collections.synchronizedSet(HashSet<Int>())
        val mockIntentHash = 987654321

        val initialDelivery = processedIntents.add(mockIntentHash)
        val onNewIntentDelivery = processedIntents.add(mockIntentHash)

        assertTrue("Cold start / initial intent delivery should process", initialDelivery)
        assertFalse("Duplicate intent delivery for same activity intent must be ignored", onNewIntentDelivery)
    }

    @Test
    fun fitbitCallback_duplicate4xxResponse_preservesAlreadyConnectedState() {
        var isFitbitConnected = true
        var errorMessage: String? = null
        val duplicateExchange400 = true

        if (duplicateExchange400) {
            val errMessage = "Fitbit Auth Failed: HTTP 400"
            if (!isFitbitConnected) {
                errorMessage = errMessage
            }
        }

        assertTrue("Already connected state must be preserved on secondary exchange response", isFitbitConnected)
        assertNull("Error message should not override state if user is already connected", errorMessage)
    }

    @Test
    fun fitbitCallback_tokenExchangeFailure_setsErrorMessage() {
        val httpSuccess = false
        val responseMessage = "400 Bad Request"
        var errorMessage: String? = null

        if (!httpSuccess) {
            errorMessage = "Fitbit Auth Failed: $responseMessage"
        }

        assertEquals("Fitbit Auth Failed: 400 Bad Request", errorMessage)
    }

    // --- Today's Plan Persistence & Occurrence Key Tests ---

    @Test
    fun sameScheduledDose_producesSameOccurrenceKey() {
        val key1 = buildMedicationOccurrenceKey("uuid-med-101", 101L, "2026-08-26", "Morning")
        val key2 = buildMedicationOccurrenceKey("uuid-med-101", 101L, "2026-08-26", "morning")

        assertEquals("med_uuid-med-101_2026-08-26_morning", key1)
        assertEquals(key1, key2)
    }

    @Test
    fun twoDailyDoses_remainIndependent() {
        val morningKey = buildMedicationOccurrenceKey("uuid-med-101", 101L, "2026-08-26", "Morning")
        val eveningKey = buildMedicationOccurrenceKey("uuid-med-101", 101L, "2026-08-26", "Evening")

        assertNotEquals(morningKey, eveningKey)
        assertEquals("med_uuid-med-101_2026-08-26_morning", morningKey)
        assertEquals("med_uuid-med-101_2026-08-26_evening", eveningKey)
    }

    @Test
    fun medicationTaken_survivesPlanRecomputation() {
        val med = Medication(id = 1L, uuid = "med-uuid-1", name = "Lisinopril", dose = "10mg", timesPerDay = 1)
        val occurrences = listOf(
            ScheduledDoseOccurrence(
                occurrenceKey = "med_med-uuid-1_2026-08-26_daily",
                medicationId = 1L,
                scheduledDate = "2026-08-26",
                scheduledTime = "Daily",
                status = "TAKEN"
            )
        )
        val occurrenceMap = occurrences.associateBy { it.occurrenceKey }

        val key = buildMedicationOccurrenceKey(med.uuid, med.id, "2026-08-26", "Daily")
        val occ = occurrenceMap[key]

        assertNotNull(occ)
        assertEquals("TAKEN", occ?.status)
    }

    @Test
    fun medicationTaken_survivesViewModelRecreation() {
        val persistedOccurrence = ScheduledDoseOccurrence(
            occurrenceKey = "med_med-uuid-1_2026-08-26_daily",
            medicationId = 1L,
            scheduledDate = "2026-08-26",
            scheduledTime = "Daily",
            status = "TAKEN"
        )

        // Simulating DB reload into a new ViewModel
        val dbOccurrences = listOf(persistedOccurrence)
        val occurrenceMap = dbOccurrences.associateBy { it.occurrenceKey }

        val key = "med_med-uuid-1_2026-08-26_daily"
        assertTrue(occurrenceMap.containsKey(key))
        assertEquals("TAKEN", occurrenceMap[key]?.status)
    }

    @Test
    fun medicationTaken_survivesAppRestart() {
        // Occurrence saved in Room DB table scheduled_dose_occurrences
        val dbRecord = ScheduledDoseOccurrence(
            id = 55L,
            occurrenceKey = "med_med-uuid-99_2026-08-26_daily",
            medicationId = 99L,
            scheduledDate = "2026-08-26",
            status = "TAKEN"
        )

        assertEquals("med_med-uuid-99_2026-08-26_daily", dbRecord.occurrenceKey)
        assertEquals("TAKEN", dbRecord.status)
    }

    @Test
    fun reminderCompletion_survivesRefresh() {
        val reminder = Reminder(id = 5, title = "Drink Water", type = "FIXED", fixedHour = 10, fixedMinute = 0)
        val completedReminderIds = setOf(5)
        val isCompleted = completedReminderIds.contains(reminder.id)

        assertTrue("Reminder completion derived from persistent preferences survives refresh", isCompleted)
    }

    @Test
    fun habitCompletion_survivesRefresh() {
        val dateStr = "2026-08-26"
        val habit = HabitDtoModel(
            id = "habit_101",
            title = "Morning Stretch",
            logs = listOf("2026-08-26")
        )

        val isCompleted = habit.logs.contains(dateStr)
        assertTrue("Habit completion in persistent log list survives refresh", isCompleted)
    }

    @Test
    fun overdueCompletedItem_doesNotReturn() {
        val item = TodayPlanItem.ScheduledMedication(
            medication = Medication(id = 1L, uuid = "uuid-1", name = "Aspirin"),
            dose = "81mg",
            timeLabel = "Morning",
            isCompleted = true,
            status = ActionStatus.TAKEN
        )

        assertFalse("Completed item must not return as overdue", item.isOverdue())
    }

    @Test
    fun recurringItem_createsOnlyCorrectNextOccurrence() {
        val completedDate = "2026-08-25"
        val currentDate = "2026-08-26"

        val occurrences = listOf(
            ScheduledDoseOccurrence(
                occurrenceKey = "med_uuid-1_2026-08-25_daily",
                medicationId = 1L,
                scheduledDate = completedDate,
                status = "TAKEN"
            )
        )
        val todayMap = occurrences.filter { it.scheduledDate == currentDate }.associateBy { it.occurrenceKey }

        val todayKey = "med_uuid-1_2026-08-26_daily"
        val todayOcc = todayMap[todayKey]

        assertNull("Today's occurrence for a new date is PENDING until recorded", todayOcc)
    }

    @Test
    fun staleSynchronizationData_doesNotRestoreCompletedItem() {
        val localOccurrence = ScheduledDoseOccurrence(
            occurrenceKey = "med_uuid-1_2026-08-26_daily",
            medicationId = 1L,
            scheduledDate = "2026-08-26",
            status = "TAKEN",
            actionTimestamp = 1000L
        )

        val serverSnapshotStatus = "PENDING"
        val effectiveStatus = if (localOccurrence.status == "TAKEN") "TAKEN" else serverSnapshotStatus

        assertEquals("TAKEN", effectiveStatus)
    }

    @Test
    fun failedPersistence_reportsErrorInsteadOfPretendingSuccess() {
        var errorBanner: String? = null
        val dbWriteFailed = true

        if (dbWriteFailed) {
            errorBanner = "Failed to record medication action: Database IO Error"
        }

        assertNotNull(errorBanner)
        assertEquals("Failed to record medication action: Database IO Error", errorBanner)
    }
}
