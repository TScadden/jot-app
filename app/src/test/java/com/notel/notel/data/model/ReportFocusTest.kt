package com.notel.notel.data.model

import com.notel.notel.data.local.DefaultCategories
import com.notel.notel.data.local.entity.Category
import org.junit.Assert.*
import org.junit.Test

class ReportFocusTest {

    private val all = DefaultCategories.all

    @Test
    fun effectiveSlug_usesStoredSlugWhenPresent() {
        val cat = all.first { it.id == 1 }
        assertEquals("symptoms", effectiveSlug(cat))
    }

    @Test
    fun effectiveSlug_fallsBackToCanonicalSlugById_whenStoredSlugIsNull() {
        // Databases created before the slug backfill store NULL slugs.
        val cat = Category(id = 1, name = "Symptoms", icon = "Favorite", colorHex = "#FF6B6B", slug = null)
        assertNull(cat.slug)
        assertEquals("symptoms", effectiveSlug(cat))
    }

    @Test
    fun effectiveSlug_unknownId_returnsEmpty() {
        val cat = Category(id = 999, name = "Weird", icon = "X", colorHex = "#000000", slug = null)
        assertEquals("", effectiveSlug(cat))
    }

    @Test
    fun healthFocus_resolvesToHealthSlugs() {
        val ids = resolveFocusCategoryIds(all, ReportFocus.Health, emptySet())
        // symptoms=1, heart_rate=3, medication=8, sleep=5, mood=6
        assertEquals(setOf(1, 3, 5, 6, 8), ids)
    }

    @Test
    fun healthFocus_stillMatches_whenStoredSlugsAreNull() {
        val nulled = all.map { it.copy(slug = null) }
        val ids = resolveFocusCategoryIds(nulled, ReportFocus.Health, emptySet())
        assertEquals(setOf(1, 3, 5, 6, 8), ids)
    }

    @Test
    fun trainingFocus_resolvesToTrainingSlugs() {
        val ids = resolveFocusCategoryIds(all, ReportFocus.Training, emptySet())
        // personal=4, heart_rate=3, calories=2
        assertEquals(setOf(2, 3, 4), ids)
    }

    @Test
    fun customFocus_usesSelectedIds_intersectedWithExisting() {
        val ids = resolveFocusCategoryIds(all, ReportFocus.Custom("migraines"), setOf(1, 5, 999))
        assertEquals(setOf(1, 5), ids) // stale id 999 dropped
    }

    @Test
    fun customFocus_emptySelection_selectsNothing() {
        assertTrue(resolveFocusCategoryIds(all, ReportFocus.Custom(), emptySet()).isEmpty())
    }

    @Test
    fun fromKey_roundTrips() {
        assertEquals(ReportFocus.Health, ReportFocus.fromKey("health"))
        assertEquals(ReportFocus.Training, ReportFocus.fromKey("training"))
        assertEquals(ReportFocus.Custom("abc"), ReportFocus.fromKey("custom", "abc"))
        assertEquals(ReportFocus.Health, ReportFocus.fromKey(null))
        assertEquals(ReportFocus.Health, ReportFocus.fromKey("bogus"))
    }

    @Test
    fun entries_exposesAllThreeOptions() {
        assertEquals(listOf("health", "training", "custom"), ReportFocus.entries.map { it.key })
    }
}
