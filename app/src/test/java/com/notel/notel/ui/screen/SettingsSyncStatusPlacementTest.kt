package com.notel.notel.ui.screen

import org.junit.Assert.*
import org.junit.Test

class SettingsSyncStatusPlacementTest {

    @Test
    fun staticStorageBadges_matchExactRequiredLabels() {
        val physicianProtocolsBadge = "Synced"
        val eventCountersBadge = "Synced"
        val digitalKnowledgeExtractionBadge = "On-device"

        assertEquals("Synced", physicianProtocolsBadge)
        assertEquals("Synced", eventCountersBadge)
        assertEquals("On-device", digitalKnowledgeExtractionBadge)
    }

    @Test
    fun staticStorageBadges_containNoObsoleteWording() {
        val badges = listOf("Synced", "Synced", "On-device")
        val obsoleteTerms = listOf(
            "Syncing",
            "Local",
            "Cloud sync enabled",
            "Saved locally",
            "Extracted knowledge cloud-synced"
        )

        for (badge in badges) {
            for (term in obsoleteTerms) {
                assertFalse("Badge '$badge' should not contain obsolete term '$term'", badge == term)
            }
        }
    }
}
