package com.notel.notel.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QuickAddParserTest {

    @Test
    fun parseInput_medicationWithDosageAndTime() {
        val input = "Took 200mg Advil at 8:30am"
        val proposals = QuickAddParser.parseInput(input)

        assertEquals(1, proposals.size)
        val p = proposals[0]
        assertEquals("MEDICATION", p.type)
        assertEquals("medication", p.categorySlug)
        assertEquals("200mg", p.dosage)
        assertEquals("8:30am", p.timeString)
        assertTrue(p.confidence >= 0.90f)
    }

    @Test
    fun parseInput_multiIntentMedicationAndSymptom() {
        val input = "Took 500mg Tylenol then had severe headache"
        val proposals = QuickAddParser.parseInput(input)

        assertEquals(2, proposals.size)
        val med = proposals[0]
        val sym = proposals[1]

        assertEquals("MEDICATION", med.type)
        assertEquals("500mg", med.dosage)

        assertEquals("SYMPTOM", sym.type)
        assertEquals("symptoms", sym.categorySlug)
        assertEquals("severe", sym.intensity)
    }

    @Test
    fun parseInput_generalNoteFallback() {
        val input = "Walked in the park for 30 minutes"
        val proposals = QuickAddParser.parseInput(input)

        assertEquals(1, proposals.size)
        assertEquals("NOTE", proposals[0].type)
        assertEquals("general", proposals[0].categorySlug)
    }
}
