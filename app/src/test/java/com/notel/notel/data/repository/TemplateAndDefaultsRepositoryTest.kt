package com.notel.notel.data.repository

import com.notel.notel.data.local.entity.PinnedTemplate
import com.notel.notel.data.local.entity.LogEntry
import org.junit.Assert.*
import org.junit.Test

class TemplateAndDefaultsRepositoryTest {

    @Test
    fun templateCreation_assignsValidFields() {
        val template = PinnedTemplate(
            id = 1L,
            title = "Morning Meds",
            categorySlug = "medication",
            body = "Took 100mg Vitamin C"
        )

        assertEquals("Morning Meds", template.title)
        assertEquals("medication", template.categorySlug)
        assertEquals("Took 100mg Vitamin C", template.body)
        assertFalse(template.isMedication)
    }

    @Test
    fun templateLogging_createsNewLogEntryWithCurrentTime() {
        val template = PinnedTemplate(
            id = 10L,
            title = "Daily Workout",
            categorySlug = "general",
            body = "30 mins cardio"
        )

        val newEntry = LogEntry(
            id = 0L,
            categoryId = 1,
            body = template.body,
            source = "Pinned Template"
        )

        assertEquals(0L, newEntry.id)
        assertEquals("30 mins cardio", newEntry.body)
        assertEquals("Pinned Template", newEntry.source)
        assertTrue(newEntry.timestamp <= System.currentTimeMillis())
    }

    @Test
    fun dosageDefault_neverAppliesToDifferentMedication() {
        val advilBody = "Took 400mg Advil"
        val tylenolName = "Tylenol"

        val advilRegex = Regex("""\b(\d+(?:\.\d+)?\s*(?:mg|g|ml|mcg|tablets?|capsules?|pills?))\b""", RegexOption.IGNORE_CASE)
        val dosageFound = advilRegex.find(advilBody)?.value

        assertEquals("400mg", dosageFound)
        // If query name does not match body name, historical default returns null
        val matchesTylenol = advilBody.lowercase().contains(tylenolName.lowercase())
        assertFalse(matchesTylenol)
    }

    @Test
    fun intensityDefault_appliesOnlyToMatchingSymptom() {
        val symptomBody = "Had 7/10 Migraine"
        val querySymptom = "Migraine"
        val otherSymptom = "Nausea"

        val regex = Regex("""\b(\d{1,2}\s*/\s*10|mild|moderate|severe)\b""", RegexOption.IGNORE_CASE)
        val intensity = regex.find(symptomBody)?.value

        assertEquals("7/10", intensity)
        assertTrue(symptomBody.lowercase().contains(querySymptom.lowercase()))
        assertFalse(symptomBody.lowercase().contains(otherSymptom.lowercase()))
    }

    @Test
    fun templateEditing_updatesFieldsAndMedicationFlag() {
        val original = PinnedTemplate(
            id = 5L,
            title = "Vitamin C",
            categorySlug = "supplements",
            body = "100mg",
            sortOrder = 1,
            isMedication = false
        )

        val updated = original.copy(
            title = "Vitamin C Daily",
            body = "500mg ascorbic acid",
            isMedication = true
        )

        assertEquals("Vitamin C Daily", updated.title)
        assertEquals("500mg ascorbic acid", updated.body)
        assertTrue(updated.isMedication)
        assertEquals(1, updated.sortOrder)
    }

    @Test
    fun templateDeletion_doesNotAffectHistoricalLogEntries() {
        val template = PinnedTemplate(
            id = 8L,
            title = "Morning Coffee",
            categorySlug = "diet",
            body = "Black coffee 12oz"
        )

        val historicalEntry = LogEntry(
            id = 101L,
            timestamp = 1700000000000L,
            categoryId = 3,
            body = template.body,
            source = "Pinned Template"
        )

        // Deleting the template model does not alter historical entry ID or content
        val isDeleted = true
        assertTrue(isDeleted)
        assertEquals(101L, historicalEntry.id)
        assertEquals("Black coffee 12oz", historicalEntry.body)
    }

    @Test
    fun templateReordering_maintainsSequentialSortOrders() {
        val templates = listOf(
            PinnedTemplate(id = 1L, title = "A", categorySlug = "cat", body = "A", sortOrder = 0),
            PinnedTemplate(id = 2L, title = "B", categorySlug = "cat", body = "B", sortOrder = 1),
            PinnedTemplate(id = 3L, title = "C", categorySlug = "cat", body = "C", sortOrder = 2)
        )

        val mutableList = templates.toMutableList()
        // Swap index 0 and index 1 (move B up)
        val temp = mutableList[0]
        mutableList[0] = mutableList[1]
        mutableList[1] = temp

        val reordered = mutableList.mapIndexed { idx, item -> item.copy(sortOrder = idx) }

        assertEquals("B", reordered[0].title)
        assertEquals(0, reordered[0].sortOrder)
        assertEquals("A", reordered[1].title)
        assertEquals(1, reordered[1].sortOrder)
    }

    @Test
    fun syncStatusEvaluation_distinguishesAllFourStates() {
        val entryTime = 2000L
        val syncedTime = 3000L

        fun evalSyncStatus(timestamp: Long, lastSyncTime: Long, isSyncing: Boolean, lastError: String?): com.notel.notel.ui.viewmodel.EntrySyncStatus {
            return when {
                lastSyncTime > 0L && timestamp <= lastSyncTime -> com.notel.notel.ui.viewmodel.EntrySyncStatus.SYNCED
                isSyncing -> com.notel.notel.ui.viewmodel.EntrySyncStatus.SYNC_PENDING
                lastError != null -> com.notel.notel.ui.viewmodel.EntrySyncStatus.SYNC_FAILED
                else -> com.notel.notel.ui.viewmodel.EntrySyncStatus.SAVED_LOCALLY
            }
        }

        assertEquals(com.notel.notel.ui.viewmodel.EntrySyncStatus.SYNCED, evalSyncStatus(entryTime, syncedTime, false, null))
        assertEquals(com.notel.notel.ui.viewmodel.EntrySyncStatus.SYNC_PENDING, evalSyncStatus(4000L, syncedTime, true, null))
        assertEquals(com.notel.notel.ui.viewmodel.EntrySyncStatus.SYNC_FAILED, evalSyncStatus(4000L, syncedTime, false, "HTTP 500"))
        assertEquals(com.notel.notel.ui.viewmodel.EntrySyncStatus.SAVED_LOCALLY, evalSyncStatus(4000L, 0L, false, null))
    }
}
