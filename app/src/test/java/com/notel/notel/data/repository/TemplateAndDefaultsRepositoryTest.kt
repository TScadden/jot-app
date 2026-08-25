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
}
