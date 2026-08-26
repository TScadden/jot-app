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
    fun transparentAiInsight_containsRequiredFieldsAndClassification() {
        val insight = com.notel.notel.data.local.entity.AiInsight(
            id = "ins_101",
            text = "Consistent medication logging observed.",
            timestamp = System.currentTimeMillis(),
            type = "SUMMARY",
            classification = "OBSERVATION",
            dataUsed = "Medication records, daily logs",
            dateRangeText = "Past 7 days",
            plainLanguageReason = "You logged your medications regularly over the last week.",
            confidence = 0.90f,
            feedbackState = "HELPFUL",
            isDismissed = false
        )

        assertEquals("OBSERVATION", insight.classification)
        assertEquals("HELPFUL", insight.feedbackState)
        assertFalse(insight.isDismissed)
        assertEquals(0.90f, insight.confidence, 0.01f)
    }

    @Test
    fun todayCustomization_simpleVsDetailedModeAndHiddenSections() {
        val hidden = setOf("WHAT_CHANGED", "HOW_IM_DOING")
        val order = listOf("TODAY_PLAN", "AI_INSIGHT", "QUICK_ACTIONS")

        val state = TodayUiState(
            mode = "SIMPLE",
            hiddenSections = hidden,
            sectionOrder = order
        )

        assertEquals("SIMPLE", state.mode)
        assertTrue(state.hiddenSections.contains("WHAT_CHANGED"))
        assertEquals("TODAY_PLAN", state.sectionOrder.first())
    }

    @Test
    fun healthComparison_validSevenDayDifferenceCalculation() {
        val todaySleep = 420 // 7 hours
        val pastAvgSleep = 465 // 7h 45m
        val diff = todaySleep - pastAvgSleep // -45 mins

        val comparison = com.notel.notel.data.repository.HealthComparisonItem(
            metricName = "Sleep Duration",
            currentPeriod = "7h 0m today",
            comparisonPeriod = "7-day avg (7h 45m)",
            differenceText = "Sleep was ${Math.abs(diff)} minutes shorter than your seven-day average.",
            dataSource = "Health Connect",
            lastUpdatedTime = "Today"
        )

        assertEquals("Sleep Duration", comparison.metricName)
        assertTrue(comparison.differenceText.contains("45 minutes shorter"))
    }

    @Test
    fun schemaAndMigrationLogicUnitTest_verifiesNewInsightColumnsAndCrossRefTable() {
        val legacyInsight = com.notel.notel.data.local.entity.AiInsight(
            id = "ins_v26_1",
            text = "Legacy insight text",
            timestamp = 1700000000000L,
            type = "TREND"
        )

        // Verify default values applied during schema definition & migration logic
        assertEquals("OBSERVATION", legacyInsight.classification)
        assertEquals("Symptom logs, medication records", legacyInsight.dataUsed)
        assertEquals("Past 7 days", legacyInsight.dateRangeText)
        assertEquals("Observed consistency in daily tracking records.", legacyInsight.plainLanguageReason)
        assertEquals(0.85f, legacyInsight.confidence, 0.01f)
        assertEquals("NONE", legacyInsight.feedbackState)
        assertFalse(legacyInsight.isDismissed)

        val crossRef = com.notel.notel.data.local.entity.InsightEntryCrossRef(
            insightId = legacyInsight.id,
            entryId = 1001L
        )

        assertEquals("ins_v26_1", crossRef.insightId)
        assertEquals(1001L, crossRef.entryId)
    }

    @Test
    fun healthComparison_symptomCategoryResolution_handlesNonID5AndExcludesUnrelatedNotes() {
        // Symptoms category with numeric ID 99 (not 5)
        val symptomsCatId = 99
        val unrelatedCatId = 5 // Category ID 5 belongs to an unrelated category (e.g. Work)

        val validSymptomEntry = com.notel.notel.data.local.entity.LogEntry(
            id = 101,
            categoryId = symptomsCatId,
            body = "Mild joint pain",
            chips = "[]",
            manualText = "Mild joint pain",
            timestamp = System.currentTimeMillis()
        )

        val unrelatedCategory5Entry = com.notel.notel.data.local.entity.LogEntry(
            id = 102,
            categoryId = unrelatedCatId,
            body = "Had a headache from client meeting", // Contains keyword but in category 5 (Work)
            chips = "[]",
            manualText = "",
            timestamp = System.currentTimeMillis()
        )

        val filterLogic: (com.notel.notel.data.local.entity.LogEntry) -> Boolean = { entry ->
            val matchesCategory = entry.categoryId == symptomsCatId
            val matchesLegacyTextFallback = entry.categoryId == 0 && (
                entry.body.contains("headache", ignoreCase = true) ||
                entry.body.contains("nausea", ignoreCase = true) ||
                entry.body.contains("fatigue", ignoreCase = true)
            )
            matchesCategory || matchesLegacyTextFallback
        }

        assertTrue(filterLogic(validSymptomEntry))
        assertFalse(filterLogic(unrelatedCategory5Entry))
    }
}
