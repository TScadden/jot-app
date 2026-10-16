package com.notel.notel.data.healthconnect

import com.notel.notel.data.model.BiomarkerPoint

/**
 * Merge semantics for the `historical_heart_rate` / `historical_hr_spikes`
 * DataStore caches.
 *
 * One rule for every writer: a fresh fetch REFRESHES the days it covers and
 * never discards the days it does not. Before this helper existed,
 * FitbitViewModel's phase-2 (14-day) fetch overwrote both caches with only
 * those 14 days, unmerged — shrinking a 172-day report window to 14 days
 * between two report runs on Oct 16, 2026. LogRepository already merged
 * (see `getDailyStatsSummary`); this object is that same merge + 180-day
 * cap, shared so the two writers cannot drift apart again.
 *
 * Fresh rows win on a date collision (the fetch exists to refresh recent
 * data). Results are sorted ascending by date (yyyy-MM-dd sorts
 * chronologically) and capped to the most recent [MAX_CACHED_DAYS] days.
 * An empty fresh fetch therefore returns the existing cache (capped and
 * sorted) instead of wiping it.
 */
object HrHistoryCacheMerge {

    const val MAX_CACHED_DAYS = 180

    /**
     * Merges daily heart-rate points. Zero/negative values are failed reads,
     * never real data (founder's standing rule), so they are dropped from
     * both sides instead of being cached or overwriting a real value.
     */
    fun mergeHeartRatePoints(
        existing: List<BiomarkerPoint>,
        fresh: List<BiomarkerPoint>
    ): List<BiomarkerPoint> {
        val merged = (existing.filter { it.value > 0 } + fresh.filter { it.value > 0 })
            .associateBy { it.date }
        return merged.values
            .sortedByDescending { it.date }
            .take(MAX_CACHED_DAYS)
            .sortedBy { it.date }
    }

    /**
     * Merges per-day HR spike summaries. Fresh rows win on a date collision.
     */
    fun mergeHrSpikes(
        existing: List<DailyHeartRateSummary>,
        fresh: List<DailyHeartRateSummary>
    ): List<DailyHeartRateSummary> {
        val merged = (existing + fresh).associateBy { it.date }
        return merged.values
            .sortedByDescending { it.date }
            .take(MAX_CACHED_DAYS)
            .sortedBy { it.date }
    }
}
