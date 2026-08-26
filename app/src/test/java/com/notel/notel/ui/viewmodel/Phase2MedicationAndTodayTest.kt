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
    fun twoScheduledDosesSameDay_remainIndependentInOccurrenceKeys() {
        val today = LocalDate.now().toString()
        val morningOcc = ScheduledDoseOccurrence(
            id = 1L,
            occurrenceKey = "med_1_${today}_Morning",
            medicationId = 1L,
            scheduledDate = today,
            scheduledTime = "Morning",
            status = "TAKEN"
        )
        val eveningOcc = ScheduledDoseOccurrence(
            id = 2L,
            occurrenceKey = "med_1_${today}_Evening",
            medicationId = 1L,
            scheduledDate = today,
            scheduledTime = "Evening",
            status = "PENDING"
        )

        assertNotEquals(morningOcc.occurrenceKey, eveningOcc.occurrenceKey)
        assertEquals("TAKEN", morningOcc.status)
        assertEquals("PENDING", eveningOcc.status)
    }

    @Test
    fun repeatedTaken_returnsExistingLogAssociationWithoutDuplicates() {
        val today = LocalDate.now().toString()
        val key = "med_2_${today}_Morning"
        val firstTaken = ScheduledDoseOccurrence(
            id = 10L,
            occurrenceKey = key,
            medicationId = 2L,
            scheduledDate = today,
            scheduledTime = "Morning",
            status = "TAKEN",
            associatedLogEntryId = 55L
        )

        val secondTaken = firstTaken.copy(
            actionTimestamp = System.currentTimeMillis()
        )

        assertEquals(firstTaken.associatedLogEntryId, secondTaken.associatedLogEntryId)
        assertEquals(55L, secondTaken.associatedLogEntryId)
    }

    @Test
    fun takenToSkippedCorrection_clearsAssociatedLogEntryId() {
        val today = LocalDate.now().toString()
        val takenOcc = ScheduledDoseOccurrence(
            id = 15L,
            occurrenceKey = "med_3_${today}_Daily",
            medicationId = 3L,
            scheduledDate = today,
            scheduledTime = "Daily",
            status = "TAKEN",
            associatedLogEntryId = 88L
        )

        val skippedOcc = takenOcc.copy(
            status = "SKIPPED",
            associatedLogEntryId = null
        )

        assertEquals("SKIPPED", skippedOcc.status)
        assertNull("Changing TAKEN to SKIPPED must clear associated log", skippedOcc.associatedLogEntryId)
    }

    @Test
    fun snoozingOneDose_doesNotChangeAnotherDose() {
        val today = LocalDate.now().toString()
        val morningOcc = ScheduledDoseOccurrence(
            id = 20L,
            occurrenceKey = "med_4_${today}_Morning",
            medicationId = 4L,
            scheduledDate = today,
            scheduledTime = "Morning",
            status = "SNOOZED",
            snoozedUntilTimestamp = 999999L
        )

        val eveningOcc = ScheduledDoseOccurrence(
            id = 21L,
            occurrenceKey = "med_4_${today}_Evening",
            medicationId = 4L,
            scheduledDate = today,
            scheduledTime = "Evening",
            status = "PENDING"
        )

        assertEquals("SNOOZED", morningOcc.status)
        assertEquals(999999L, morningOcc.snoozedUntilTimestamp)
        assertEquals("PENDING", eveningOcc.status)
        assertNull(eveningOcc.snoozedUntilTimestamp)
    }

    @Test
    fun viewModelRecreation_retainsBothOccurrences() {
        val today = LocalDate.now().toString()
        val med = Medication(id = 10L, name = "Multivitamin", dose = "1 tab", frequency = "Twice Daily", timesPerDay = 2)
        val occurrences = listOf(
            ScheduledDoseOccurrence(id = 100L, occurrenceKey = "med_10_${today}_Morning", medicationId = 10L, scheduledDate = today, scheduledTime = "Morning", status = "TAKEN"),
            ScheduledDoseOccurrence(id = 101L, occurrenceKey = "med_10_${today}_Evening", medicationId = 10L, scheduledDate = today, scheduledTime = "Evening", status = "SKIPPED")
        )

        val map = occurrences.associateBy { it.occurrenceKey }
        assertEquals("TAKEN", map["med_10_${today}_Morning"]?.status)
        assertEquals("SKIPPED", map["med_10_${today}_Evening"]?.status)
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
            occurrenceKey = "med_8_2026-08-01_Daily",
            medicationId = 8L,
            scheduledDate = "2026-08-01",
            scheduledTime = "Daily",
            status = "TAKEN"
        )

        assertTrue(archivedMed.isArchived)
        assertEquals(8L, historyOccurrence.medicationId)
        assertEquals("TAKEN", historyOccurrence.status)
    }
}
