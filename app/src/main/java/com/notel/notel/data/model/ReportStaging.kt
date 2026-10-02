package com.notel.notel.data.model

import com.notel.notel.data.local.entity.LogEntry
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Staged AI context (Phase 1, WS-B).
 *
 * For long histories we cannot dump thousands of log DTOs into the AI
 * prompt. Instead the device builds deterministic per-window aggregates
 * (weekly for spans up to ~4 months, monthly beyond) over the FULL range,
 * and ships only a recent raw window of individual entries for detail.
 * The server is told the aggregates are authoritative for totals and the
 * raw entries are the recent window only.
 */
data class StagedEntries(
    /** Most-recent raw entries sent as individual DTOs. */
    val recentEntries: List<LogEntry>,
    /** Deterministic window aggregates covering the full range ("" when not staged). */
    val aggregateText: String,
    val totalEntries: Int,
    val staged: Boolean,
    /** Days between the oldest recent entry and now (>= 1 when non-empty). */
    val recentWindowDays: Int
)

private const val STAGE_THRESHOLD = 250
private const val RECENT_WINDOW_SIZE = 150
private const val WEEKLY_WINDOW_MAX_SPAN_DAYS = 120
private const val WEEK_MS = 7L * 24 * 60 * 60 * 1000
private const val MONTH_MS = 30L * 24 * 60 * 60 * 1000

private data class WindowAggregate(
    val startMs: Long,
    val endMs: Long,
    val entryCount: Int,
    val distinctDays: Int,
    val topCategories: List<Pair<String, Int>>
)

fun stageEntriesForPrompt(
    entries: List<LogEntry>,
    categoriesMap: Map<Int, String>,
    range: ClinicalReportRange,
    nowMs: Long = System.currentTimeMillis()
): StagedEntries {
    val sorted = entries.sortedByDescending { it.timestamp }
    if (sorted.size <= STAGE_THRESHOLD) {
        val recentDays = if (sorted.isEmpty()) 0
        else (((nowMs - sorted.minOf { it.timestamp }).coerceAtLeast(0) / (24 * 60 * 60 * 1000L)).toInt() + 1)
        return StagedEntries(
            recentEntries = sorted,
            aggregateText = "",
            totalEntries = sorted.size,
            staged = false,
            recentWindowDays = recentDays
        )
    }

    val recent = sorted.take(RECENT_WINDOW_SIZE)
    val recentDays = (((nowMs - recent.minOf { it.timestamp }).coerceAtLeast(0) / (24 * 60 * 60 * 1000L)).toInt() + 1)
        .coerceAtLeast(1)

    val windowMs = if (range.durationDays <= WEEKLY_WINDOW_MAX_SPAN_DAYS) WEEK_MS else MONTH_MS
    val windowLabel = if (windowMs == WEEK_MS) "weekly" else "monthly"
    val zone = try { ZoneId.of(range.timezoneId) } catch (_: Exception) { ZoneId.systemDefault() }
    val dateFmt = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US).withZone(zone)

    // Bucket every entry (ascending) into fixed windows from the range start.
    val rangeStart = range.startEpochMs.coerceAtLeast(0L)
    val windows = sorted.groupBy { entry ->
        ((entry.timestamp - rangeStart).coerceAtLeast(0L) / windowMs).toInt()
    }.toSortedMap().map { (bucket, bucketEntries) ->
        val wStart = rangeStart + bucket * windowMs
        val wEnd = minOf(wStart + windowMs - 1, range.endEpochMs)
        val byCategory = bucketEntries.groupingBy {
            categoriesMap[it.categoryId] ?: "Category ${it.categoryId}"
        }.eachCount().toList().sortedByDescending { it.second }.take(6)
        WindowAggregate(
            startMs = wStart,
            endMs = wEnd,
            entryCount = bucketEntries.size,
            distinctDays = bucketEntries.map { it.timestamp / (24 * 60 * 60 * 1000L) }.toSet().size,
            topCategories = byCategory
        )
    }

    val text = buildString {
        append("HISTORY AGGREGATES — deterministic on-device $windowLabel counts covering the FULL report range. ")
        append("These are authoritative for totals; the raw entries below are only the ${recent.size} most recent logs (last ~$recentDays days) for detail. ")
        append("Do not treat the raw entries as the full history.\n")
        windows.forEach { w ->
            append("- ${dateFmt.format(Instant.ofEpochMilli(w.startMs))} to ${dateFmt.format(Instant.ofEpochMilli(w.endMs))}: ")
            append("${w.entryCount} entries on ${w.distinctDays} days")
            if (w.topCategories.isNotEmpty()) {
                append("; " + w.topCategories.joinToString(", ") { (name, count) -> "$name $count" })
            }
            append("\n")
        }
    }.trimEnd()

    return StagedEntries(
        recentEntries = recent,
        aggregateText = text,
        totalEntries = sorted.size,
        staged = true,
        recentWindowDays = recentDays
    )
}
