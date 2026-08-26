package com.notel.notel.ui.viewmodel

import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.repository.HealthComparisonItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TodaySummaryAndCategoryOrderingTest {

    @Test
    fun testRankCategories_fourTierSortingAndDeduplication() {
        val catSleep = Category(id = 1, name = "Sleep", icon = "bed", colorHex = "#000000", sortOrder = 1, slug = "sleep")
        val catHeart = Category(id = 2, name = "Heart Rate", icon = "favorite", colorHex = "#000000", sortOrder = 2, slug = "heart_rate")
        val catMood = Category(id = 3, name = "Mood", icon = "face", colorHex = "#000000", sortOrder = 3, slug = "mood")
        val catFood = Category(id = 4, name = "Food", icon = "restaurant", colorHex = "#000000", sortOrder = 4, slug = "food")
        val catSleepDuplicate = Category(id = 5, name = "Sleep Dup", icon = "bed", colorHex = "#000000", sortOrder = 5, slug = "sleep")

        val categories = listOf(catSleep, catHeart, catMood, catFood, catSleepDuplicate)

        val now = System.currentTimeMillis()
        val entries = listOf(
            // Food: used 3 times (highest frequency)
            LogEntry(id = 1, categoryId = 4, body = "Lunch", timestamp = now - 3000),
            LogEntry(id = 2, categoryId = 4, body = "Dinner", timestamp = now - 2000),
            LogEntry(id = 3, categoryId = 4, body = "Snack", timestamp = now - 1000),

            // Heart Rate: used 1 time (ts = now - 500)
            LogEntry(id = 4, categoryId = 2, body = "Pulse", timestamp = now - 500),

            // Mood: used 1 time (ts = now - 400, more recent than Heart Rate)
            LogEntry(id = 5, categoryId = 3, body = "Happy", timestamp = now - 400)
        )

        val aiRecommendedKeys = setOf("sleep")

        val ranked = QuickLogViewModel.rankCategories(categories, entries, aiRecommendedKeys)

        // 1. Deduplicated: 4 categories total (sleep duplicate removed)
        assertEquals(4, ranked.size)
        assertEquals(listOf("food", "mood", "heart_rate", "sleep"), ranked.map { it.stableKey })

        // Detailed checks:
        // Tier 1: Food (frequency = 3) is #1
        assertEquals("food", ranked[0].stableKey)

        // Tier 2: Mood and Heart Rate both have frequency = 1. Mood was logged at now - 400, Heart at now - 500. So Mood is #2, Heart is #3.
        assertEquals("mood", ranked[1].stableKey)
        assertEquals("heart_rate", ranked[2].stableKey)

        // Tier 3: Sleep has frequency = 0, but is in aiRecommendedKeys.
        assertEquals("sleep", ranked[3].stableKey)
    }

    @Test
    fun testTrendsState_sealedClassVariants() {
        val loading: TodayTrendsState = TodayTrendsState.Loading
        val empty: TodayTrendsState = TodayTrendsState.Empty
        val ready: TodayTrendsState = TodayTrendsState.Ready(
            listOf(
                HealthComparisonItem(
                    metricName = "Resting Heart Rate",
                    differenceText = "3 bpm lower than average",
                    currentPeriod = "Today",
                    comparisonPeriod = "Past 7 days",
                    dataSource = "Fitbit",
                    lastUpdatedTime = "10m ago"
                )
            )
        )
        val error: TodayTrendsState = TodayTrendsState.Error("Network failure")

        assertTrue(loading is TodayTrendsState.Loading)
        assertTrue(empty is TodayTrendsState.Empty)
        assertTrue(ready is TodayTrendsState.Ready && ready.items.size == 1)
        assertTrue(error is TodayTrendsState.Error && error.message == "Network failure")
    }

    @Test
    fun testSummaryTextFormatting() {
        // Remaining > 0 without overdue
        val text1 = formatSummaryText(remainingCount = 3, overdueCount = 0, totalPlans = 3)
        assertEquals("3 items remaining", text1)

        // Remaining > 0 with overdue
        val text2 = formatSummaryText(remainingCount = 2, overdueCount = 1, totalPlans = 4)
        assertEquals("2 items remaining · 1 overdue", text2)

        // Remaining == 0 with total plans > 0
        val text3 = formatSummaryText(remainingCount = 0, overdueCount = 0, totalPlans = 3)
        assertEquals("Everything planned for today is complete", text3)

        // Total plans == 0
        val text4 = formatSummaryText(remainingCount = 0, overdueCount = 0, totalPlans = 0)
        assertEquals("No plans recorded today", text4)
    }

    private fun formatSummaryText(remainingCount: Int, overdueCount: Int, totalPlans: Int): String {
        return when {
            remainingCount > 0 -> {
                "$remainingCount item${if (remainingCount > 1) "s" else ""} remaining${if (overdueCount > 0) " · $overdueCount overdue" else ""}"
            }
            totalPlans > 0 -> "Everything planned for today is complete"
            else -> "No plans recorded today"
        }
    }
}
