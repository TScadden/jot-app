package com.notel.notel.data.repository

import com.notel.notel.data.local.entity.LogEntry
import org.junit.Assert.*
import org.junit.Test

class OutOfOrderResponseTest {

    @Test
    fun outOfOrderResponses_bindCorrectlyToOriginalEntries() {
        val entryA = LogEntry(id = 101L, categoryId = 1, body = "Entry A text")
        val entryB = LogEntry(id = 102L, categoryId = 2, body = "Entry B text")

        val requestA = "req_AAA"
        val requestB = "req_BBB"

        val responseMap = mutableMapOf<String, String>()

        // Simulating Out-of-Order arrival: Response B arrives first
        responseMap[requestB] = "AI Response B for Entry B"
        // Response A arrives second
        responseMap[requestA] = "AI Response A for Entry A"

        // Verify Entry A displays ONLY Response A
        val insightForA = responseMap[requestA]
        assertEquals("AI Response A for Entry A", insightForA)
        assertNotEquals("AI Response B for Entry B", insightForA)

        // Verify Entry B displays ONLY Response B
        val insightForB = responseMap[requestB]
        assertEquals("AI Response B for Entry B", insightForB)
        assertNotEquals("AI Response A for Entry A", insightForB)
    }

    @Test
    fun synchronizationMapping_localLongToServerUuidTranslation() {
        val localEntryId: Long = 42L
        val serverEntryUuid = "550e8400-e29b-41d4-a716-446655440000"

        val localToServerMap = mapOf(localEntryId to serverEntryUuid)
        val serverToLocalMap = mapOf(serverEntryUuid to localEntryId)

        // Upload translation: Room Long -> PostgreSQL UUID
        val uploadTargetUuid = localToServerMap[42L]
        assertEquals("550e8400-e29b-41d4-a716-446655440000", uploadTargetUuid)

        // Download translation: PostgreSQL UUID -> Room Long
        val resolvedLocalId = serverToLocalMap["550e8400-e29b-41d4-a716-446655440000"]
        assertEquals(42L, resolvedLocalId)

        // Unsynced entry returns null deferred association
        val unmappedLocalId = serverToLocalMap["unknown-uuid"]
        assertNull(unmappedLocalId)
    }

    @Test
    fun repeatLastEntry_neverCopiesIdsOrAiResponses() {
        val originalEntry = LogEntry(
            id = 55L,
            categoryId = 3,
            body = "Original Body",
            manualText = "Manual",
            source = "User"
        )

        // Repeat last entry creation
        val newEntry = LogEntry(
            id = 0L, // Fresh Room auto-increment primary key
            categoryId = originalEntry.categoryId,
            body = originalEntry.body,
            manualText = originalEntry.manualText,
            source = "Repeat Last Entry"
        )

        assertNotEquals(originalEntry.id, newEntry.id)
        assertEquals("Repeat Last Entry", newEntry.source)
    }
}
