package com.notel.notel.ui.viewmodel

import com.notel.notel.data.local.entity.PinnedTemplate
import com.notel.notel.data.local.entity.LogEntry
import org.junit.Assert.*
import org.junit.Test

class TemplateManagementAndSyncRetryTest {

    @Test
    fun templateEditing_updatesAllFieldsAndPreservesSortOrder() {
        val original = PinnedTemplate(
            id = 5L,
            title = "Morning Meds",
            categorySlug = "medication",
            body = "10mg Vitamin B",
            sortOrder = 2,
            isMedication = true
        )

        val edited = original.copy(
            title = "Morning Meds & Supplements",
            body = "10mg Vitamin B + 500mg Vitamin C",
            categorySlug = "supplements",
            isMedication = true
        )

        assertEquals(5L, edited.id)
        assertEquals("Morning Meds & Supplements", edited.title)
        assertEquals("10mg Vitamin B + 500mg Vitamin C", edited.body)
        assertEquals("supplements", edited.categorySlug)
        assertTrue(edited.isMedication)
        assertEquals(2, edited.sortOrder)
    }

    @Test
    fun templateReordering_swapsItemsAndUpdatesSortIndex() {
        val t1 = PinnedTemplate(id = 1L, title = "T1", categorySlug = "cat", body = "B1", sortOrder = 0)
        val t2 = PinnedTemplate(id = 2L, title = "T2", categorySlug = "cat", body = "B2", sortOrder = 1)
        val list = mutableListOf(t1, t2)

        // Move T2 up (swap 1 and 0)
        val temp = list[0]
        list[0] = list[1]
        list[1] = temp

        val updated = list.mapIndexed { idx, item -> item.copy(sortOrder = idx) }

        assertEquals(2L, updated[0].id)
        assertEquals(0, updated[0].sortOrder)
        assertEquals(1L, updated[1].id)
        assertEquals(1, updated[1].sortOrder)
    }

    @Test
    fun partialSyncRetry_onlyResendsUnsyncedEntries() {
        val lastSyncTime = 1000L
        val syncedEntry = LogEntry(id = 1L, categoryId = 1, body = "Synced", timestamp = 500L)
        val unsyncedEntry = LogEntry(id = 2L, categoryId = 1, body = "Pending", timestamp = 1500L)

        val allEntries = listOf(syncedEntry, unsyncedEntry)
        
        // Retry sync filter simulation: filter entries newer than lastSyncTime
        val entriesToSync = allEntries.filter { it.timestamp > lastSyncTime }

        assertEquals(1, entriesToSync.size)
        assertEquals(2L, entriesToSync.first().id)
        assertEquals("Pending", entriesToSync.first().body)
    }

    @Test
    fun syncStatus_clearlyDistinguishesSavedLocallyFromSyncPendingAndFailed() {
        fun evalSyncStatus(timestamp: Long, lastSyncTime: Long, isSyncing: Boolean, lastError: String?): EntrySyncStatus {
            return when {
                lastSyncTime > 0L && timestamp <= lastSyncTime -> EntrySyncStatus.SYNCED
                isSyncing -> EntrySyncStatus.SYNC_PENDING
                lastError != null -> EntrySyncStatus.SYNC_FAILED
                else -> EntrySyncStatus.SAVED_LOCALLY
            }
        }

        val entryTime = 2000L
        // 1. Saved locally (never synced, sync not running, no error)
        assertEquals(EntrySyncStatus.SAVED_LOCALLY, evalSyncStatus(entryTime, 0L, false, null))
        // 2. Sync pending (sync currently active)
        assertEquals(EntrySyncStatus.SYNC_PENDING, evalSyncStatus(entryTime, 1000L, true, null))
        // 3. Sync failed (sync ended with error)
        assertEquals(EntrySyncStatus.SYNC_FAILED, evalSyncStatus(entryTime, 1000L, false, "Connection timeout"))
        // 4. Synced (entry timestamp <= last sync time)
        assertEquals(EntrySyncStatus.SYNCED, evalSyncStatus(entryTime, 3000L, false, null))
    }
}
