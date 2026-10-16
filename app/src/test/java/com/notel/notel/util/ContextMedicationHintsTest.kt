package com.notel.notel.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Personal Context hint scans ONLY names that already exist as
 * medication entries (active ∪ archived) — no general drug lexicon.
 */
class ContextMedicationHintsTest {

    private val entries = listOf("Ivabradine", "Escitalopram", "SS-31", "Vitamin D3")

    @Test
    fun `mentioned entry names are returned with the entry casing`() {
        val mentioned = ContextMedicationHints.findMentionedMedicationNames(
            "Currently taking ivabradine twice a day and vitamin d3 in the morning.",
            entries
        )
        assertEquals(listOf("Ivabradine", "Vitamin D3"), mentioned)
    }

    @Test
    fun `archived entry names are detected too - active union archived`() {
        // Escitalopram is the archived/ended case from the Oct 16 report: an
        // ended entry still named in the context is exactly the contradiction
        // the hint exists to surface.
        val mentioned = ContextMedicationHints.findMentionedMedicationNames(
            "Escitalopram has been helping my mood.",
            entries
        )
        assertEquals(listOf("Escitalopram"), mentioned)
    }

    @Test
    fun `hyphenated names match`() {
        val mentioned = ContextMedicationHints.findMentionedMedicationNames(
            "Started SS-31 peptide last week.",
            entries
        )
        assertEquals(listOf("SS-31"), mentioned)
    }

    @Test
    fun `a name that only appears inside a longer word does not match`() {
        // "cat" occurs inside "medication" but is glued to other letters on
        // both sides, so it must not be reported as a mention.
        val mentioned = ContextMedicationHints.findMentionedMedicationNames(
            "I take this medication daily.",
            listOf("Cat")
        )
        assertTrue(mentioned.isEmpty())
    }

    @Test
    fun `names with no entry are never reported - there is no lexicon`() {
        val mentioned = ContextMedicationHints.findMentionedMedicationNames(
            "Pyridostigmine was mentioned in an old note.",
            entries
        )
        assertTrue(mentioned.isEmpty())
    }

    @Test
    fun `blank context and blank or tiny names produce no hints`() {
        assertTrue(ContextMedicationHints.findMentionedMedicationNames("", entries).isEmpty())
        assertTrue(
            ContextMedicationHints.findMentionedMedicationNames(
                "D3 and B12 daily.",
                listOf("D3", "  ", "")
            ).isEmpty()
        )
    }

    @Test
    fun `duplicate entries are reported once`() {
        val mentioned = ContextMedicationHints.findMentionedMedicationNames(
            "Ivabradine, ivabradine, IVABRADINE.",
            listOf("Ivabradine", "ivabradine")
        )
        assertEquals(listOf("Ivabradine"), mentioned)
    }
}
