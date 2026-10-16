package com.notel.notel.data.repository

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The clinical report's structured medications channel depends on this
 * mapping carrying current AND discontinued entries, with dates. The
 * pre-fix mapping filtered to present-only and hardcoded isArchived=false,
 * which erased discontinued medications (and every start date) before the
 * report payload was built — a medication ended Oct 16, 2026 could then be
 * narrated as the current regimen (v3 defect shape).
 */
class DecodeProfileMedicationsTest {

    // DataStore JSON as written by the SettingsViewModel Medication
    // serializer: UUID String ids, string dates, "Present" for current meds.
    private val fixtureJson = """
        [
          {"id":"uuid-iva","name":"Ivabradine","startDate":"2026-05-26","endDate":"Present","isPresent":true,"dose":"7.5 mg","frequency":"Twice Daily","updatedAt":1000,"isDeleted":false},
          {"id":"uuid-esc","name":"Escitalopram","startDate":"2026-09-01","endDate":"2026-10-16","isPresent":false,"dose":"10 mg","frequency":"Daily","updatedAt":2000,"isDeleted":false},
          {"id":"uuid-old","name":"Sertraline","startDate":"2026-01-01","endDate":"2026-08-01","isPresent":false,"dose":"50 mg","frequency":"Daily","updatedAt":500,"isDeleted":true}
        ]
    """.trimIndent()

    @Test
    fun `current and discontinued entries are both carried through, deleted excluded`() {
        val meds = decodeProfileMedications(fixtureJson)
        assertEquals(listOf("Ivabradine", "Escitalopram"), meds.map { it.name })
    }

    @Test
    fun `archived flag reflects isPresent instead of being hardcoded false`() {
        val meds = decodeProfileMedications(fixtureJson)
        assertFalse(meds.first { it.name == "Ivabradine" }.isArchived)
        assertTrue(meds.first { it.name == "Escitalopram" }.isArchived)
    }

    @Test
    fun `start and end dates survive the mapping`() {
        val meds = decodeProfileMedications(fixtureJson)
        val iva = meds.first { it.name == "Ivabradine" }
        assertEquals("2026-05-26", iva.startedDate)
        assertNull("a current medication has no end date", iva.endedDate)
        val esc = meds.first { it.name == "Escitalopram" }
        assertEquals("2026-09-01", esc.startedDate)
        assertEquals("2026-10-16", esc.endedDate)
    }

    @Test
    fun `dose and frequency are carried verbatim`() {
        val meds = decodeProfileMedications(fixtureJson)
        val iva = meds.first { it.name == "Ivabradine" }
        assertEquals("7.5 mg", iva.dose)
        assertEquals("Twice Daily", iva.frequency)
    }
}
