package com.notel.notel.data.model

import com.notel.notel.data.local.entity.LogEntry
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Deterministic chart math for the Progress Reports preview and PDF
 * (Phase 2, WS-D).
 *
 * One set of pure functions feeds BOTH the on-screen preview charts and the
 * PDF charts, from the SAME snapshot — so preview and export agree for
 * identical inputs by construction. No Android dependencies: unit-tested.
 *
 * Rules honored everywhere:
 * - Missing data is preserved as gaps (a bucket with no points has
 *   [ChartBucket.hasData] == false and is never rendered as zero).
 * - Unlike units are never mixed: each metric is bucketed independently.
 * - Long histories are aggregated (daily / weekly / monthly chosen by span)
 *   and the bucket size is always labeled next to the chart.
 */

private const val DAY_MS = 24 * 60 * 60 * 1000L

enum class BucketSize(val label: String) {
    DAILY("daily"),
    WEEKLY("weekly"),
    MONTHLY("monthly")
}

/** Resolves the aggregation bucket for a span. Pure; unit-tested. */
fun bucketSizeForSpan(spanDays: Long): BucketSize = when {
    spanDays <= 45 -> BucketSize.DAILY
    spanDays <= 400 -> BucketSize.WEEKLY
    else -> BucketSize.MONTHLY
}

/**
 * One aggregated bucket of a continuous metric series (sleep, HR, HRV...).
 * [mean] is null when the bucket holds no points — a gap, not a zero.
 */
data class ChartBucket(
    val startMs: Long,
    val endMs: Long,
    val label: String,
    val mean: Double?,
    val pointCount: Int
) {
    val hasData: Boolean get() = mean != null
}

/**
 * Aggregates timestamped (ms, value) points into fixed calendar buckets from
 * [rangeStartMs]. Buckets with no points are kept as gaps. Labels are
 * calendar-anchored in [timezoneId] ("Mar 3", "Mar 3 – Mar 9", "Mar 2026").
 */
fun bucketizeSeries(
    points: List<Pair<Long, Double>>,
    rangeStartMs: Long,
    rangeEndMs: Long,
    timezoneId: String,
    bucketSize: BucketSize? = null
): List<ChartBucket> {
    val start = rangeStartMs.coerceAtLeast(0L)
    val end = maxOf(rangeEndMs, start + 1)
    val zone = try { ZoneId.of(timezoneId) } catch (_: Exception) { ZoneId.systemDefault() }
    val spanDays = (end - start) / DAY_MS
    val size = bucketSize ?: bucketSizeForSpan(spanDays)

    val bucketMs = when (size) {
        BucketSize.DAILY -> DAY_MS
        BucketSize.WEEKLY -> 7L * DAY_MS
        BucketSize.MONTHLY -> 30L * DAY_MS
    }
    val bucketCount = ((end - start + bucketMs - 1) / bucketMs).toInt().coerceAtLeast(1)

    val dayFmt = DateTimeFormatter.ofPattern("MMM d", Locale.US).withZone(zone)
    val monthFmt = DateTimeFormatter.ofPattern("MMM yyyy", Locale.US).withZone(zone)

    fun labelFor(index: Int): String {
        val bStart = start + index * bucketMs
        return when (size) {
            BucketSize.DAILY -> dayFmt.format(Instant.ofEpochMilli(bStart))
            BucketSize.WEEKLY -> {
                val bEnd = minOf(bStart + bucketMs - 1, end)
                "${dayFmt.format(Instant.ofEpochMilli(bStart))} – ${dayFmt.format(Instant.ofEpochMilli(bEnd))}"
            }
            BucketSize.MONTHLY -> monthFmt.format(Instant.ofEpochMilli(bStart))
        }
    }

    val grouped = points
        .filter { it.first in start..end }
        .groupBy { ((it.first - start).coerceAtLeast(0L) / bucketMs).toInt().coerceAtMost(bucketCount - 1) }

    return (0 until bucketCount).map { index ->
        val values = grouped[index].orEmpty().map { it.second }
        ChartBucket(
            startMs = start + index * bucketMs,
            endMs = minOf(start + (index + 1) * bucketMs - 1, end),
            label = labelFor(index),
            mean = if (values.isEmpty()) null else values.average(),
            pointCount = values.size
        )
    }
}

/**
 * One aggregated bucket of discrete counts (symptom frequency, training
 * volume bars). [count] is an honest 0..N — bars may legitimately be zero,
 * but buckets OUTSIDE the data are not fabricated: only buckets inside the
 * range are emitted.
 */
data class CountBucket(
    val startMs: Long,
    val endMs: Long,
    val label: String,
    val count: Int
)

/**
 * Buckets log entries into fixed calendar windows for bar charts. Entries
 * are pre-filtered by the caller (focus categories, symptom subset, ...).
 */
fun bucketizeCounts(
    entries: List<LogEntry>,
    rangeStartMs: Long,
    rangeEndMs: Long,
    timezoneId: String,
    bucketSize: BucketSize? = null
): List<CountBucket> {
    val buckets = bucketizeSeries(
        points = entries.map { it.timestamp to 1.0 },
        rangeStartMs = rangeStartMs,
        rangeEndMs = rangeEndMs,
        timezoneId = timezoneId,
        bucketSize = bucketSize
    )
    return buckets.map { b ->
        CountBucket(b.startMs, b.endMs, b.label, b.pointCount)
    }
}

/** Parses an ISO yyyy-MM-dd date key to start-of-day millis (UTC). Null-safe. */
fun isoDateKeyToMs(dateKey: String): Long? = try {
    val parts = dateKey.split("-")
    if (parts.size != 3) return null
    val y = parts[0].toInt(); val m = parts[1].toInt(); val d = parts[2].toInt()
    java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply {
        isLenient = false
        set(y, m - 1, d, 0, 0, 0); set(java.util.Calendar.MILLISECOND, 0)
    }.timeInMillis
} catch (_: Exception) { null }

/**
 * Converts a snapshot's yyyy-MM-dd keyed metric series to (epochMs, value)
 * points for [bucketizeSeries]. Unparseable keys are dropped.
 */
fun seriesToPoints(series: List<Pair<String, Double>>): List<Pair<Long, Double>> =
    series.mapNotNull { (key, value) ->
        isoDateKeyToMs(key)?.let { it to value }
    }

/**
 * Top symptom categories by DISTINCT recorded days (not raw entry count —
 * a bad day with 10 logs counts once). Returns (categoryName, distinctDays,
 * entryCount). Pure; unit-tested.
 */
fun topSymptomsByDistinctDays(
    entries: List<LogEntry>,
    categoriesMap: Map<Int, String>,
    symptomCategoryIds: Set<Int>,
    limit: Int = 5
): List<Triple<String, Int, Int>> {
    val symptomEntries = entries.filter { it.categoryId in symptomCategoryIds }
    return symptomEntries
        .groupBy { it.categoryId }
        .map { (catId, catEntries) ->
            val distinctDays = catEntries.map { it.timestamp / DAY_MS }.toSet().size
            Triple(categoriesMap[catId] ?: "Category $catId", distinctDays, catEntries.size)
        }
        .sortedWith(compareByDescending<Triple<String, Int, Int>> { it.second }.thenByDescending { it.third })
        .take(limit)
}

/**
 * Distinct calendar days with at least one entry, over the range span.
 * Returns (daysWithEntries, spanDays).
 */
fun loggingCoverage(entries: List<LogEntry>, rangeStartMs: Long, rangeEndMs: Long): Pair<Int, Int> {
    val start = rangeStartMs.coerceAtLeast(0L)
    val end = maxOf(rangeEndMs, start)
    val spanDays = ((end - start) / DAY_MS + 1).toInt().coerceAtLeast(1)
    val days = entries.map { it.timestamp / DAY_MS }.toSet().size
    return days to spanDays
}

/**
 * Mini overall-timeline: entry counts per week across the whole range for
 * the compact page-1 strip. Caps at 52 buckets (older ranges collapse into
 * the earliest bucket) so it never crams.
 */
fun overallTimeline(entries: List<LogEntry>, rangeStartMs: Long, rangeEndMs: Long): List<CountBucket> {
    val start = rangeStartMs.coerceAtLeast(0L)
    val end = maxOf(rangeEndMs, start)
    val spanDays = (end - start) / DAY_MS
    val bucketMs = if (spanDays <= 120) 7L * DAY_MS else 30L * DAY_MS
    val bucketCount = (((end - start) / bucketMs).toInt() + 1).coerceIn(1, 52)
    val zone = ZoneId.systemDefault()
    val fmt = DateTimeFormatter.ofPattern("MMM d", Locale.US).withZone(zone)
    val grouped = entries.filter { it.timestamp in start..end }
        .groupBy { ((it.timestamp - start).coerceAtLeast(0L) / bucketMs).toInt().coerceAtMost(bucketCount - 1) }
    return (0 until bucketCount).map { i ->
        val bStart = start + i * bucketMs
        CountBucket(
            startMs = bStart,
            endMs = minOf(bStart + bucketMs - 1, end),
            label = fmt.format(Instant.ofEpochMilli(bStart)),
            count = grouped[i]?.size ?: 0
        )
    }
}

/** Clamp helper used by chart renderers: index of nearest bucket at/after [ms]. */
fun bucketIndexAtOrAfter(buckets: List<ChartBucket>, ms: Long): Int =
    buckets.indexOfFirst { it.endMs >= ms }.coerceAtLeast(0)
