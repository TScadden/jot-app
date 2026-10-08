package com.notel.notel.util

/**
 * Tabs Lab HRV composite metrics. Pure functions, no Android dependencies.
 *
 * The balance-factor HRV index is adapted from the open-source Manawa Pace app
 * (Copyright 2026 Chris Hilder, Apache License 2.0; see the app's About /
 * third-party-licenses screen). The composite blends RMSSD and SDNN into one
 * number: index = ln(RMSSD) * 15.3 * balanceFactor, where
 * balanceFactor = (RMSSD / SDNN) / 0.5 clamped to [0, 1].
 *
 * The balance factor penalizes presentations where RMSSD is low relative to
 * SDNN, a pattern that can appear in sympathetic-dominant states common in
 * dysautonomia. This is an informational composite only. It is not a medical
 * measurement, not a diagnosis, and does not suggest any treatment.
 */
object HrvMetrics {

    private const val INDEX_SCALE = 15.3
    private const val BALANCE_REFERENCE_RATIO = 0.5

    // HR response-lag measurement constants (Tabs Lab feature 3).
    private const val LAG_THRESHOLD_DELTA_BPM = 30
    private const val LAG_THRESHOLD_FLOOR_BPM = 100
    private const val LAG_THRESHOLD_WINDOW_DAYS = 7
    private const val LAG_CROSSING_DEBOUNCE_MILLIS = 5 * 60 * 1000L
    private const val LAG_FALL_TIMEOUT_MILLIS = 30 * 60 * 1000L
    private const val LAG_FALL_DROP_BPM = 3
    private const val LAG_FALL_SUSTAIN_SAMPLES = 3

    /**
     * Computes the balance-factor HRV index, or null when the inputs are not
     * usable. Zero or negative RMSSD/SDNN are never real readings (biometric
     * zero-value rule) and always yield null, never a charted or cached value.
     */
    fun balanceFactorHrvIndex(rmssdMs: Double?, sdnnMs: Double?): Double? {
        if (rmssdMs == null || sdnnMs == null) return null
        if (rmssdMs <= 0.0 || sdnnMs <= 0.0) return null
        val balanceFactor = ((rmssdMs / sdnnMs) / BALANCE_REFERENCE_RATIO).coerceIn(0.0, 1.0)
        return kotlin.math.ln(rmssdMs) * INDEX_SCALE * balanceFactor
    }

    /**
     * Number of days of history feeding the exertion-threshold window.
     */
    fun exertionThresholdWindowDays(): Int = LAG_THRESHOLD_WINDOW_DAYS

    /**
     * Personal exertion threshold for the HR response-lag metric: the median of
     * the per-day daytime medians across the window, plus [LAG_THRESHOLD_DELTA_BPM]
     * bpm, floored at [LAG_THRESHOLD_FLOOR_BPM] bpm. Median-of-medians is the
     * outlier handling: a spike-heavy day cannot drag the threshold up.
     *
     * @param daytimeSamplesByDay daytime (7am-10pm, Tabs' standing convention)
     * HR samples per day, most recent day first. Any order is fine.
     * @return threshold in bpm, or null when no day has usable samples. Samples
     * of 0 bpm or less are never real readings (biometric zero-value rule) and
     * are dropped, never averaged in.
     */
    fun exertionThresholdBpm(daytimeSamplesByDay: List<List<Int>>): Int? {
        val dailyMedians = daytimeSamplesByDay.mapNotNull { day ->
            val valid = day.filter { it > 0 }
            if (valid.isEmpty()) null else median(valid.map { it.toDouble() })
        }
        if (dailyMedians.isEmpty()) return null
        val threshold = median(dailyMedians) + LAG_THRESHOLD_DELTA_BPM
        return threshold.coerceAtLeast(LAG_THRESHOLD_FLOOR_BPM.toDouble()).toInt()
    }

    /**
     * Detects HR response-lag events in one day's intraday series and returns
     * one entry per event: seconds from the threshold crossing until HR starts
     * falling, or null when the event is censored.
     *
     * A crossing counts only when the first sample at or above the threshold
     * is preceded by a 5-minute window that holds at least one sample and in
     * which every sample is below the threshold (debounce against sampling
     * noise). "Starts falling" is the first point after the
     * post-crossing peak where HR sits at least [LAG_FALL_DROP_BPM] bpm below
     * that peak across [LAG_FALL_SUSTAIN_SAMPLES] consecutive samples
     * (hysteresis against jitter). The event is censored to null when HR does
     * not start falling within 30 minutes, or when a second crossing begins
     * first. A null is never replaced with a fabricated number: this extends
     * the biometric zero-value rule into a general signal-quality rule.
     *
     * Samples of 0 bpm or less are treated as missing (never real readings)
     * and skipped, never counted as a fall or a below-threshold reading.
     */
    fun responseLagEvents(
        samples: List<Pair<Long, Int>>,
        thresholdBpm: Int
    ): List<Double?> {
        val valid = samples.filter { it.second > 0 }.sortedBy { it.first }
        val events = mutableListOf<Double?>()
        var i = 0
        while (i < valid.size) {
            val crossingIdx = findCrossing(valid, i, thresholdBpm)
            if (crossingIdx == null) break
            i = trackEvent(valid, crossingIdx, thresholdBpm, events)
        }
        return events
    }

    /**
     * Daily median of the non-censored event lags, or null when there are no
     * measurable events that day.
     */
    fun dailyMedianResponseLag(lagsSeconds: List<Double?>): Double? {
        val measurable = lagsSeconds.filterNotNull()
        if (measurable.isEmpty()) return null
        return median(measurable)
    }

    /**
     * Finds the first threshold crossing at or after [fromIdx]: a sample at or
     * above the threshold whose preceding 5-minute window holds at least one
     * sample and every sample in it is below the threshold.
     */
    private fun findCrossing(
        valid: List<Pair<Long, Int>>,
        fromIdx: Int,
        thresholdBpm: Int
    ): Int? {
        for (j in fromIdx until valid.size) {
            val (t, bpm) = valid[j]
            if (bpm < thresholdBpm) continue
            // The debounce looks at the full 5-minute history before t, not
            // just samples after the resume index: a same-day earlier event
            // must not let a non-debounced spike through.
            val window = valid.subList(0, j).filter { (wt, _) ->
                wt >= t - LAG_CROSSING_DEBOUNCE_MILLIS && wt < t
            }
            if (window.isNotEmpty() && window.all { it.second < thresholdBpm }) {
                return j
            }
        }
        return null
    }

    /**
     * Tracks one event from its crossing index, appends its lag (or null when
     * censored) to [events], and returns the index from which the next
     * crossing search should resume.
     */
    private fun trackEvent(
        valid: List<Pair<Long, Int>>,
        crossingIdx: Int,
        thresholdBpm: Int,
        events: MutableList<Double?>
    ): Int {
        val (tCross, _) = valid[crossingIdx]
        var peak = valid[crossingIdx].second
        var belowRunStart: Long? = null
        var k = crossingIdx + 1
        while (k < valid.size) {
            val (t, bpm) = valid[k]
            if (bpm > peak) peak = bpm

            // Timeout: no confirmed fall within 30 minutes. Censor, and resume
            // the next search after the window so the same crossing cannot
            // re-trigger.
            if (t - tCross > LAG_FALL_TIMEOUT_MILLIS) {
                events.add(null)
                val resumeAt = valid.indexOfFirst { it.first > tCross + LAG_FALL_TIMEOUT_MILLIS }
                return if (resumeAt == -1) valid.size else resumeAt
            }

            // Fall confirmation: 3 consecutive samples at least 3 bpm below
            // the post-crossing peak.
            if (k + LAG_FALL_SUSTAIN_SAMPLES - 1 < valid.size) {
                val window = valid.subList(k, k + LAG_FALL_SUSTAIN_SAMPLES)
                if (window.all { it.second <= peak - LAG_FALL_DROP_BPM }) {
                    events.add((t - tCross) / 1000.0)
                    return k + LAG_FALL_SUSTAIN_SAMPLES
                }
            }

            // Second crossing before a confirmed fall: censor this event and
            // restart tracking at the new crossing.
            if (bpm >= thresholdBpm) {
                val start = belowRunStart
                if (start != null && t - start >= LAG_CROSSING_DEBOUNCE_MILLIS) {
                    events.add(null)
                    return trackEvent(valid, k, thresholdBpm, events)
                }
                belowRunStart = null
            } else {
                if (belowRunStart == null) belowRunStart = t
            }
            k++
        }
        // Series ended before the event resolved: censor, never fabricate.
        events.add(null)
        return valid.size
    }

    private fun median(values: List<Double>): Double {
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 1) sorted[mid]
        else (sorted[mid - 1] + sorted[mid]) / 2.0
    }
}
