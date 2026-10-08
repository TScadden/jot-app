package com.notel.notel.data.model

import com.notel.notel.data.local.entity.LogEntry
import org.junit.Assert.*
import org.junit.Test

class ReportStagingTest {

    private val now = 1_757_000_000_000L
    private val dayMs = 24 * 60 * 60 * 1000L
    private val categories = mapOf(1 to "Symptoms", 5 to "Sleep")

    private fun entry(id: Long, daysAgo: Long, categoryId: Int = 1) = LogEntry(
        id = id,
        categoryId = categoryId,
        body = "note $id",
        timestamp = now - daysAgo * dayMs
    )

    private fun rangeFor(days: Long) =
        ReportRange.Custom(now - days * dayMs, now).toClinicalReportRange(now)

    @Test
    fun underThreshold_notStaged_allEntriesSentRaw() {
        val entries = (1..250).map { entry(it.toLong(), (it % 20).toLong()) }
        val staged = stageEntriesForPrompt(entries, categories, rangeFor(30), now)
        assertFalse(staged.staged)
        assertEquals("", staged.aggregateText)
        assertEquals(250, staged.recentEntries.size)
        assertEquals(250, staged.totalEntries)
    }

    @Test
    fun overThreshold_staged_recentWindowIs150MostRecent() {
        // 300 entries over 10 days (30/day); weekly windows (span <= 120d).
        val entries = (1..300).map { entry(it.toLong(), ((it - 1) / 30).toLong()) }
        val staged = stageEntriesForPrompt(entries, categories, rangeFor(10), now)
        assertTrue(staged.staged)
        assertEquals(150, staged.recentEntries.size)
        assertEquals(300, staged.totalEntries)
        // Most recent first: ids 1..30 are day 0 (most recent).
        assertEquals(1L, staged.recentEntries.first().id)
        assertEquals(150L, staged.recentEntries.last().id)
        assertTrue(staged.aggregateText.contains("HISTORY AGGREGATES"))
        assertTrue(staged.aggregateText.contains("weekly"))
    }

    @Test
    fun staged_aggregatesCoverFullRangeWithCorrectCounts() {
        // 10-day range -> two 7-day windows anchored at range start:
        // [day-10, day-3) holds days-ago 4..9 (180 entries),
        // [day-3, day+4) holds days-ago 0..3 (120 entries).
        val entries = (1..300).map { entry(it.toLong(), ((it - 1) / 30).toLong()) }
        val staged = stageEntriesForPrompt(entries, categories, rangeFor(10), now)
        assertTrue(staged.aggregateText.contains("180 entries"))
        assertTrue(staged.aggregateText.contains("120 entries"))
        assertTrue(staged.aggregateText.contains("Symptoms 180"))
    }

    @Test
    fun longSpan_usesMonthlyWindows() {
        // 300 entries over 200 days -> monthly windows (span > 120d).
        val entries = (1..300).map { entry(it.toLong(), ((it - 1) % 200).toLong()) }
        val staged = stageEntriesForPrompt(entries, categories, rangeFor(200), now)
        assertTrue(staged.staged)
        assertTrue(staged.aggregateText.contains("monthly"))
        assertFalse(staged.aggregateText.contains("weekly"))
    }

    @Test
    fun emptyEntries_notStaged() {
        val staged = stageEntriesForPrompt(emptyList(), categories, rangeFor(30), now)
        assertFalse(staged.staged)
        assertTrue(staged.recentEntries.isEmpty())
        assertEquals(0, staged.totalEntries)
        assertEquals(0, staged.recentWindowDays)
    }

    @Test
    fun boundary_251_entries_stages() {
        val entries = (1..251).map { entry(it.toLong(), 1L) }
        val staged = stageEntriesForPrompt(entries, categories, rangeFor(30), now)
        assertTrue(staged.staged)
        assertEquals(150, staged.recentEntries.size)
        assertEquals(251, staged.totalEntries)
    }

    @Test
    fun recentWindowDays_reflectsOldestRecentEntry() {
        val entries = (1..300).map { entry(it.toLong(), ((it - 1) / 30).toLong()) }
        val staged = stageEntriesForPrompt(entries, categories, rangeFor(60), now)
        // Recent window = 150 most recent = entries from days 0..4 -> 5 days.
        assertEquals(5, staged.recentWindowDays)
    }
}
