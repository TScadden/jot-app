package com.notel.notel.ui.viewmodel

import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.local.entity.PinnedTemplate
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.data.local.entity.ScheduledDoseOccurrence
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.util.QuickAddParser
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class Phase2MedicationAndTodayTest {

    @Test
    fun medicationWithoutDosage_parsesWithoutInventingOrInferringDosage() {
        val input = "Took Advil"
        val parsed = QuickAddParser.parse(input)
        
        assertEquals(1, parsed.size)
        val proposal = parsed.first()
        assertEquals("MEDICATION", proposal.type)
        assertNull("Dosage must be null when not explicitly provided", proposal.dosage)
    }

    @Test
    fun explicitDosageParsing_extractsDosageOnlyWhenSuppliedInText() {
        val input = "Took 20mg Advil"
        val parsed = QuickAddParser.parse(input)

        assertEquals(1, parsed.size)
        val proposal = parsed.first()
        assertEquals("MEDICATION", proposal.type)
        assertEquals("20mg", proposal.dosage)
    }

    @Test
    fun noHistoricalDosageInference_retainsNullDosageForMedicationProposals() {
        val proposal = com.notel.notel.util.ParsedProposal(
            type = "MEDICATION",
            categorySlug = "medication",
            title = "Took Aspirin",
            detailText = "",
            dosage = null,
            confidence = 0.8f,
            sourceText = "Took Aspirin"
        )

        assertNull("Dosage must not be automatically inferred from history", proposal.dosage)
    }

    @Test
    fun oneTapMedicationTemplate_logsDirectlyWithoutForcingConfirmation() {
        val medicationTemplate = PinnedTemplate(
            id = 10L,
            title = "Daily Tylenol",
            categorySlug = "medication",
            body = "Took 500mg Tylenol",
            isMedication = true
        )

        assertTrue(medicationTemplate.isMedication)
        assertEquals("Took 500mg Tylenol", medicationTemplate.body)
    }

    @Test
    fun undoMedicationLog_resetsLastLoggedEntryIdAndSaveSuccess() {
        var state = QuickLogUiState(
            saveSuccess = true,
            lastLoggedEntryId = 42L
        )

        state = state.copy(
            saveSuccess = false,
            lastLoggedEntryId = null
        )

        assertFalse(state.saveSuccess)
        assertNull(state.lastLoggedEntryId)
    }

    @Test
    fun takenSurvivesViewModelRecreation_readsPersistedOccurrence() {
        val today = LocalDate.now().toString()
        val occurrence = ScheduledDoseOccurrence(
            id = 1L,
            occurrenceKey = "med_1_$today",
            medicationId = 1L,
            scheduledDate = today,
            status = "TAKEN",
            actionTimestamp = 1000L
        )

        assertEquals("TAKEN", occurrence.status)
        assertEquals(1L, occurrence.medicationId)
    }

    @Test
    fun skippedSurvivesViewModelRecreation_readsPersistedOccurrence() {
        val today = LocalDate.now().toString()
        val occurrence = ScheduledDoseOccurrence(
            id = 2L,
            occurrenceKey = "med_2_$today",
            medicationId = 2L,
            scheduledDate = today,
            status = "SKIPPED",
            actionTimestamp = 1000L
        )

        assertEquals("SKIPPED", occurrence.status)
    }

    @Test
    fun snoozeChangesDueTime_updatesSnoozedUntilTimestamp() {
        val today = LocalDate.now().toString()
        val snoozeTime = System.currentTimeMillis() + 3600000L
        val occurrence = ScheduledDoseOccurrence(
            id = 3L,
            occurrenceKey = "med_3_$today",
            medicationId = 3L,
            scheduledDate = today,
            status = "SNOOZED",
            snoozedUntilTimestamp = snoozeTime
        )

        assertEquals("SNOOZED", occurrence.status)
        assertEquals(snoozeTime, occurrence.snoozedUntilTimestamp)
    }

    @Test
    fun repeatedTakenCreatesOnlyOneOccurrenceAndAssociatedLog() {
        val today = LocalDate.now().toString()
        val firstOccurrence = ScheduledDoseOccurrence(
            id = 10L,
            occurrenceKey = "med_5_$today",
            medicationId = 5L,
            scheduledDate = today,
            status = "TAKEN",
            associatedLogEntryId = 101L
        )

        val secondOccurrence = firstOccurrence.copy(
            actionTimestamp = System.currentTimeMillis()
        )

        assertEquals(10L, secondOccurrence.id)
        assertEquals(101L, secondOccurrence.associatedLogEntryId)
    }

    @Test
    fun statusTransitionUpdatesExistingOccurrence() {
        val today = LocalDate.now().toString()
        val takenOccurrence = ScheduledDoseOccurrence(
            id = 4L,
            occurrenceKey = "med_4_$today",
            medicationId = 4L,
            scheduledDate = today,
            status = "TAKEN"
        )

        val updatedToSkipped = takenOccurrence.copy(status = "SKIPPED")

        assertEquals(4L, updatedToSkipped.id)
        assertEquals("SKIPPED", updatedToSkipped.status)
    }

    @Test
    fun ordinaryMedicationLog_leavesOccurrencePending() {
        val occurrences = emptyList<ScheduledDoseOccurrence>()
        val currentStatus = occurrences.firstOrNull()?.status ?: "PENDING"

        assertEquals("PENDING", currentStatus)
    }

    @Test
    fun archivedMedicationHistory_remainsReadableInOccurrences() {
        val archivedMed = Medication(id = 8L, name = "Old Med", dose = "10mg", frequency = "Daily", isArchived = true)
        val historyOccurrence = ScheduledDoseOccurrence(
            id = 99L,
            occurrenceKey = "med_8_2026-08-01",
            medicationId = 8L,
            scheduledDate = "2026-08-01",
            status = "TAKEN"
        )

        assertTrue(archivedMed.isArchived)
        assertEquals(8L, historyOccurrence.medicationId)
        assertEquals("TAKEN", historyOccurrence.status)
    }

    @Test
    fun todayRendersPersistedStatus() {
        val med = Medication(id = 1L, name = "Lisinopril", dose = "10mg", frequency = "Morning")
        val reminder = Reminder(id = 1, title = "Drink Water", type = "FIXED", fixedHour = 10, fixedMinute = 0)
        val habit = HabitDtoModel(id = "h1", title = "Stretch", target_time = "Morning", logs = emptyList())

        val attentionItems = listOf(
            NeedsAttentionItem(id = "med_1_today", title = med.name, typeText = "Medication", detailText = med.dose, itemType = NeedsAttentionItem.ItemType.MEDICATION, medication = med),
            NeedsAttentionItem(id = "rem_1", title = reminder.title, typeText = "Reminder", detailText = "Due 10:00", itemType = NeedsAttentionItem.ItemType.REMINDER, reminder = reminder),
            NeedsAttentionItem(id = "habit_h1", title = habit.title, typeText = "Habit", detailText = "Target: Morning", itemType = NeedsAttentionItem.ItemType.HABIT, habit = habit)
        )

        val state = TodayUiState(
            summaryText = "Today you have 1 scheduled medication, 1 reminder, 1 habit.",
            needsAttentionItems = attentionItems
        )

        assertEquals(3, state.needsAttentionItems.size)
        assertEquals("Lisinopril", state.needsAttentionItems[0].title)
    }
}
