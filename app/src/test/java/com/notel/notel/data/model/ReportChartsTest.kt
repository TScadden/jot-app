package com.notel.notel.data.model

import com.notel.notel.data.local.entity.LogEntry
import org.junit.Assert.*
import org.junit.Test

class ReportChartsTest {

    private val dayMs = 24 * 60 * 60 * 1000L
    // Fixed "now": 2026-10-01 12:00 UTC (Thursday).
    private val now = 1_790_496_000_000L
    private val zone = "UTC"

    private fun entry(dayOffset: Long, categoryId: Int = 1, id: Long = 0): LogEntry =
        LogEntry(id = id, timestamp = now - dayOffset * dayMs, categoryId = categoryId, body = "x")

    @Test
    fun bucketSizeForSpan_dailyWeeklyMonthly() {
        assertEquals(BucketSize.DAILY, bucketSizeForSpan(30))
        assertEquals(BucketSize.DAILY, bucketSizeForSpan(45))
        assertEquals(BucketSize.WEEKLY, bucketSizeForSpan(46))
        assertEquals(BucketSize.WEEKLY, bucketSizeForSpan(400))
        assertEquals(BucketSize.MONTHLY, bucketSizeForSpan(401))
    }

    @Test
    fun bucketizeSeries_dailyMeanAndGaps() {
        val start = now - 4 * dayMs
        val points = listOf(
            start to 6.0,
            (start + dayMs) to 8.0,
            // day 2: gap (no points)
            (start + 3 * dayMs) to 7.0
        )
        val buckets = bucketizeSeries(points, start, now, zone, BucketSize.DAILY)
        assertEquals(4, buckets.size) // 4 daily buckets over the 4-day span
        assertEquals(6.0, buckets[0].mean!!, 1e-9)
        assertEquals(8.0, buckets[1].mean!!, 1e-9)
        assertNull(buckets[2].mean) // gap preserved, not zero
        assertFalse(buckets[2].hasData)
        assertEquals(7.0, buckets[3].mean!!, 1e-9)
    }

    @Test
    fun bucketizeSeries_weeklyAggregationLabeled() {
        val start = now - 60 * dayMs
        val points = (0 until 60).map { d -> (start + d * dayMs) to (d % 7).toDouble() }
        val buckets = bucketizeSeries(points, start, now, zone)
        // 60-day span -> weekly buckets
        assertTrue(buckets.size in 8..10)
        assertTrue(buckets.all { it.pointCount == 7 || !it.hasData || it == buckets.last() })
        assertTrue(buckets[0].label.contains("–"))
    }

    @Test
    fun bucketizeSeries_pointsOutsideRangeDropped() {
        val start = now - 4 * dayMs
        val points = listOf((start - 10 * dayMs) to 99.0, (now + 10 * dayMs) to 99.0)
        val buckets = bucketizeSeries(points, start, now, zone, BucketSize.DAILY)
        assertTrue(buckets.none { it.hasData })
    }

    @Test
    fun bucketizeCounts_countsEntriesPerBucket() {
        val start = now - 2 * dayMs
        val entries = listOf(entry(0, id = 1), entry(0, id = 2), entry(1, id = 3))
        val buckets = bucketizeCounts(entries, start, now, zone, BucketSize.DAILY)
        val counts = buckets.map { it.count }
        assertEquals(3, counts.sum())
        // Honest zeros inside the range are allowed for count buckets.
        assertTrue(counts.any { it == 0 })
    }

    @Test
    fun topSymptomsByDistinctDays_ranksByDaysNotEntries() {
        val cats = mapOf(1 to "Headache", 2 to "Nausea")
        // Headache: 10 entries but only 2 distinct days. Nausea: 3 entries on 3 days.
        val entries = (0 until 10).map { entry(dayOffset = (it % 2).toLong(), categoryId = 1, id = it.toLong()) } +
            (0 until 3).map { entry(dayOffset = it.toLong() + 5, categoryId = 2, id = (100 + it).toLong()) }
        val top = topSymptomsByDistinctDays(entries, cats, setOf(1, 2), limit = 2)
        assertEquals(2, top.size)
        assertEquals("Nausea", top[0].first)
        assertEquals(3, top[0].second)
        assertEquals("Headache", top[1].first)
        assertEquals(2, top[1].second)
    }

    @Test
    fun loggingCoverage_countsDistinctDays() {
        val entries = listOf(entry(0, id = 1), entry(0, id = 2), entry(5, id = 3))
        val (days, span) = loggingCoverage(entries, now - 9 * dayMs, now)
        assertEquals(2, days)
        assertEquals(10, span)
    }

    @Test
    fun overallTimeline_capsBuckets() {
        val entries = (0 until 800).map { entry(dayOffset = it.toLong(), id = it.toLong()) }
        val timeline = overallTimeline(entries, now - 800 * dayMs, now)
        assertTrue(timeline.size <= 52)
        assertEquals(800, timeline.sumOf { it.count })
    }

    @Test
    fun isoDateKeyToMs_parsesAndRejectsGarbage() {
        assertNotNull(isoDateKeyToMs("2026-09-15"))
        assertNull(isoDateKeyToMs("not-a-date"))
        assertNull(isoDateKeyToMs("2026-13-99"))
        assertNull(isoDateKeyToMs(""))
    }
}
