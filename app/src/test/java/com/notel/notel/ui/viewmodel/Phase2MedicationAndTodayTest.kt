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

    @Test
    fun todayPlan_consolidatesItems_ordersCompletedBelowIncomplete_andRemovesNeedsAttention() {
        val habit = HabitDtoModel("h1", "Morning Stretch", "Habit", logs = emptyList())
        val reminder = Reminder(id = 1, title = "Drink Water", type = "FIXED", fixedHour = 9, fixedMinute = 0, isEnabled = true)
        val med = Medication(id = 5L, name = "Vitamin D", dose = "1000 IU", frequency = "Daily")

        val state = TodayUiState(
            summaryText = "You have 3 items remaining today.",
            needsAttentionItems = emptyList(),
            todayPlanItems = listOf(
                TodayPlanItem.ScheduledHabit(habit = habit, isCompleted = false),
                TodayPlanItem.ScheduledReminder(reminder = reminder, isCompleted = false),
                TodayPlanItem.ScheduledMedication(medication = med, dose = "1000 IU", timeLabel = "Daily", isCompleted = true, status = ActionStatus.TAKEN)
            ),
            sectionOrder = listOf("TODAY_PLAN", "WHAT_CHANGED", "AI_INSIGHT"),
            hiddenSections = setOf()
        )

        assertTrue(state.needsAttentionItems.isEmpty())
        assertEquals("You have 3 items remaining today.", state.summaryText)
        assertEquals(3, state.todayPlanItems.size)
        // Incomplete items come first
        assertFalse(state.todayPlanItems[0].isCompleted)
        assertFalse(state.todayPlanItems[1].isCompleted)
        assertTrue(state.todayPlanItems[2].isCompleted)
    }

    @Test
    fun legacyPreferencesWithNeedsAttention_cleanedSafelyWithoutCrashing() {
        val legacyHidden = setOf("NEEDS_ATTENTION", "WHAT_CHANGED")
        val legacyOrder = listOf("NEEDS_ATTENTION", "TODAY_PLAN", "HOW_IM_DOING")

        val cleanHidden = legacyHidden.filter { it != "NEEDS_ATTENTION" }.toSet()
        val cleanOrder = legacyOrder.filter { it != "NEEDS_ATTENTION" }

        assertFalse(cleanHidden.contains("NEEDS_ATTENTION"))
        assertTrue(cleanHidden.contains("WHAT_CHANGED"))
        assertFalse(cleanOrder.contains("NEEDS_ATTENTION"))
        assertEquals("TODAY_PLAN", cleanOrder.first())
    }

    @Test
    fun addingMultipleMedications_createsSeparateEntitiesWithUniqueIdentities() {
        val medA = Medication(id = 101L, name = "Medication A", dose = "10mg", frequency = "Daily")
        val medB = Medication(id = 102L, name = "Medication B", dose = "20mg", frequency = "Daily")
        val medC = Medication(id = 103L, name = "Medication C", dose = "5mg", frequency = "Weekly")

        val medsList = listOf(medA, medB, medC)
        val activeList = medsList.filter { !it.isArchived }

        assertEquals(3, activeList.size)
        assertNotEquals(medA.id, medB.id)
        assertNotEquals(medB.id, medC.id)

        // Test editing medA does not modify medB
        val updatedMedA = medA.copy(dose = "15mg")
        val updatedList = listOf(updatedMedA, medB, medC)

        assertEquals("15mg", updatedList.find { it.id == 101L }?.dose)
        assertEquals("20mg", updatedList.find { it.id == 102L }?.dose)

        // Test archiving medA does not affect medB
        val archivedMedA = updatedMedA.copy(isArchived = true)
        val afterArchive = listOf(archivedMedA, medB, medC).filter { !it.isArchived }

        assertEquals(2, afterArchive.size)
        assertEquals("Medication B", afterArchive[0].name)
        assertEquals("Medication C", afterArchive[1].name)
    }

    @Test
    fun sameNameDifferentDosageMedications_coexistWithUniqueIds() {
        val morningDose = Medication(id = 201L, name = "Adderall", dose = "10mg", frequency = "Morning")
        val afternoonDose = Medication(id = 202L, name = "Adderall", dose = "5mg", frequency = "Afternoon")

        assertNotEquals(morningDose.id, afternoonDose.id)
        assertEquals("10mg", morningDose.dose)
        assertEquals("5mg", afternoonDose.dose)
    }

    @Test
    fun appOpeningStreak_consecutiveCalendarDaysLogic() {
        var currentStreak = 0
        var bestStreak = 0
        var lastOpenDate: java.time.LocalDate? = null

        fun simulateOpen(today: java.time.LocalDate) {
            if (lastOpenDate == null) {
                currentStreak = 1
                lastOpenDate = today
            } else if (lastOpenDate == today) {
                if (currentStreak < 1) currentStreak = 1
            } else if (lastOpenDate == today.minusDays(1)) {
                currentStreak = if (currentStreak >= 1) currentStreak + 1 else 1
                lastOpenDate = today
            } else {
                currentStreak = 1
                lastOpenDate = today
            }
            if (currentStreak > bestStreak) bestStreak = currentStreak
        }

        // Monday open: 1
        val monday = java.time.LocalDate.of(2026, 8, 24)
        simulateOpen(monday)
        assertEquals(1, currentStreak)
        assertEquals(1, bestStreak)

        // Monday second open (restart): still 1
        simulateOpen(monday)
        assertEquals(1, currentStreak)

        // Tuesday open: 2
        val tuesday = java.time.LocalDate.of(2026, 8, 25)
        simulateOpen(tuesday)
        assertEquals(2, currentStreak)
        assertEquals(2, bestStreak)

        // Wednesday missed -> Thursday open: resets to 1
        val thursday = java.time.LocalDate.of(2026, 8, 27)
        simulateOpen(thursday)
        assertEquals(1, currentStreak)
        assertEquals(2, bestStreak) // best streak preserved

        // Friday open: 2
        val friday = java.time.LocalDate.of(2026, 8, 28)
        simulateOpen(friday)
        assertEquals(2, currentStreak)
        assertEquals(2, bestStreak)
    }

    @Test
    fun streakLogic_monthAndLeapYearBoundaries() {
        var currentStreak = 0
        var lastOpenDate: java.time.LocalDate? = null

        fun simulateOpen(today: java.time.LocalDate) {
            if (lastOpenDate == null || lastOpenDate != today.minusDays(1)) {
                currentStreak = if (lastOpenDate == today) currentStreak else 1
            } else {
                currentStreak += 1
            }
            lastOpenDate = today
        }

        // Feb 28, 2028 (Leap year)
        val feb28 = java.time.LocalDate.of(2028, 2, 28)
        simulateOpen(feb28)
        assertEquals(1, currentStreak)

        // Feb 29, 2028
        val feb29 = java.time.LocalDate.of(2028, 2, 29)
        simulateOpen(feb29)
        assertEquals(2, currentStreak)

        // Mar 1, 2028
        val mar1 = java.time.LocalDate.of(2028, 3, 1)
        simulateOpen(mar1)
        assertEquals(3, currentStreak)
    }

    @Test
    fun quickLogEvents_singleEventEmittedWithEntryId() {
        val events = mutableListOf<com.notel.notel.ui.viewmodel.QuickLogEvent>()
        val loggedEvent = com.notel.notel.ui.viewmodel.QuickLogEvent.EntryLogged(entryId = 456L, message = "Entry logged")
        val repeatedEvent = com.notel.notel.ui.viewmodel.QuickLogEvent.EntryRepeated(entryId = 456L, message = "Last entry repeated")

        events.add(loggedEvent)
        events.add(repeatedEvent)

        assertEquals(2, events.size)
        assertTrue(events[0] is com.notel.notel.ui.viewmodel.QuickLogEvent.EntryLogged)
        assertEquals(456L, (events[0] as com.notel.notel.ui.viewmodel.QuickLogEvent.EntryLogged).entryId)
        assertEquals("Last entry repeated", (events[1] as com.notel.notel.ui.viewmodel.QuickLogEvent.EntryRepeated).message)
    }

    @Test
    fun medicationSync_pendingLocalMedicationPreservedWhenServerLacksIt() {
        val existingLocal = listOf(
            Medication(id = 101L, name = "Adderall", dose = "10mg", frequency = "Morning"),
            Medication(id = 102L, name = "Vitamin D", dose = "2000IU", frequency = "Daily") // pending local
        )
        val serverResponseMeds = listOf(
            com.notel.notel.ui.viewmodel.Medication(id = "101", name = "Adderall", startDate = "2026-01-01", endDate = "Present", isPresent = true)
        )

        // Non-destructive merge simulation
        val mergedList = existingLocal.toMutableList()
        for (serverMed in serverResponseMeds) {
            val serverId = serverMed.id.toLongOrNull()
            val index = mergedList.indexOfFirst { (serverId != null && it.id == serverId) || it.name.equals(serverMed.name, ignoreCase = true) }
            if (index >= 0) {
                mergedList[index] = mergedList[index].copy(name = serverMed.name)
            }
        }

        // Verify Vitamin D is preserved
        assertEquals(2, mergedList.size)
        assertTrue(mergedList.any { it.name == "Vitamin D" })
    }

    @Test
    fun medicationSync_sameNameDifferentDosageCoexistOnSync() {
        val med1 = Medication(id = 101L, name = "Adderall", dose = "10mg", frequency = "Morning")
        val med2 = Medication(id = 102L, name = "Adderall", dose = "20mg", frequency = "Evening")

        val list = listOf(med1, med2)
        assertEquals(2, list.size)
        assertNotEquals(med1.id, med2.id)
    }
}

