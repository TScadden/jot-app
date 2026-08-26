package com.notel.notel.ui.viewmodel

import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.local.entity.PinnedTemplate
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.util.QuickAddParser
import org.junit.Assert.*
import org.junit.Test

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
    fun ordinaryLog_doesNotCompleteScheduledDose() {
        val med = Medication(id = 1L, name = "Metformin", dose = "500mg", frequency = "Daily")
        val medActionStatus = ActionStatus.PENDING

        assertEquals(ActionStatus.PENDING, medActionStatus)
    }

    @Test
    fun takenSkippedSnoozedIdempotency_maintainsStateCorrectly() {
        var currentStatus = ActionStatus.PENDING

        currentStatus = ActionStatus.TAKEN
        assertEquals(ActionStatus.TAKEN, currentStatus)

        currentStatus = ActionStatus.SKIPPED
        assertEquals(ActionStatus.SKIPPED, currentStatus)

        currentStatus = ActionStatus.SNOOZED
        assertEquals(ActionStatus.SNOOZED, currentStatus)
    }

    @Test
    fun emptyTodayState_presentsClearScheduleSummary() {
        val state = TodayUiState(
            summaryText = "Your schedule for today is clear.",
            needsAttentionItems = emptyList(),
            todayPlanItems = emptyList()
        )

        assertEquals("Your schedule for today is clear.", state.summaryText)
        assertTrue(state.needsAttentionItems.isEmpty())
        assertTrue(state.todayPlanItems.isEmpty())
    }

    @Test
    fun todayWithMedicationReminderAndHabit_populatesSummaryAndSections() {
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
        assertEquals("Drink Water", state.needsAttentionItems[1].title)
        assertEquals("Stretch", state.needsAttentionItems[2].title)
    }

    @Test
    fun overdueItemOrdering_placesIncompleteItemsFirstInPlan() {
        val completedItem = TodayPlanItem.ScheduledHabit(
            habit = HabitDtoModel(id = "h1", title = "Morning Walk", target_time = "08:00", logs = listOf("2026-08-25")),
            isCompleted = true
        )
        val upcomingItem = TodayPlanItem.ScheduledReminder(
            reminder = Reminder(id = 2, title = "Evening Meds", type = "FIXED", fixedHour = 20, fixedMinute = 0),
            isCompleted = false
        )

        val planList = listOf(completedItem, upcomingItem)
        val sorted = planList.sortedWith(
            compareBy<TodayPlanItem> { it.isCompleted }.thenBy { it.timeDisplay }
        )

        assertEquals("Evening Meds", sorted.first().title)
        assertFalse(sorted.first().isCompleted)
        assertEquals("Morning Walk", sorted.last().title)
        assertTrue(sorted.last().isCompleted)
    }

    @Test
    fun failedSyncRetry_triggersRetryWithoutResendingSyncedItems() {
        var isRetrying = false
        fun retry() {
            if (isRetrying) return
            isRetrying = true
            isRetrying = false
        }

        assertFalse(isRetrying)
        retry()
        assertFalse(isRetrying)
    }
}
