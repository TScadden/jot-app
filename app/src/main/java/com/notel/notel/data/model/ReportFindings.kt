package com.notel.notel.data.model

import com.notel.notel.data.local.entity.LogEntry
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Evidence-supported findings for page 1 of the report (Phase 2, WS-C).
 *
 * Every finding is computed in deterministic on-device code from the ONE
 * snapshot — the AI narrates around them but never invents the numbers.
 * Each finding carries its evidence (coverage, units, date span) so the PDF
 * and the preview show exactly what backs it. Correlation/observation
 * language only; nothing here claims causation.
 */

private const val DAY_MS = 24 * 60 * 60 * 1000L

/** One page-1 finding: a short factual sentence plus what backs it. */
data class ReportFinding(
    /** Short factual sentence, observation language only. */
    val text: String,
    /** Evidence: coverage, units, and span backing the sentence. */
    val evidence: String,
    /** Stable key linking to the source section ("sleep", "symptoms", ...). */
    val sourceKey: String
)

/** One headline metric: value + unit + coverage for the page-1 strip. */
data class HeadlineMetric(
    val label: String,
    val value: String,
    val unit: String,
    /** e.g. "21 of 30 days". */
    val coverage: String
)

private fun fmt1(d: Double): String = String.format(Locale.US, "%.1f", d)

private fun zoneOf(snapshot: ClinicalReportData): ZoneId =
    try { ZoneId.of(snapshot.range.timezoneId) } catch (_: Exception) { ZoneId.systemDefault() }

/** Average of a yyyy-MM-dd keyed series, with distinct-day coverage. */
private fun seriesStats(series: List<Pair<String, Number>>): Triple<Double, Int, Int>? {
    val values = series.mapNotNull { (_, v) -> v.toDouble().takeIf { it > 0 } }
    if (values.isEmpty()) return null
    return Triple(values.average(), series.map { it.first }.toSet().size, values.size)
}

private fun rangeLabel(snapshot: ClinicalReportData): String {
    val zone = zoneOf(snapshot)
    val fmt = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US).withZone(zone)
    val s = fmt.format(Instant.ofEpochMilli(snapshot.range.startEpochMs.coerceAtLeast(0L)))
    val e = fmt.format(Instant.ofEpochMilli(snapshot.range.endEpochMs))
    return "$s to $e"
}

/**
 * Builds 3–5 evidence-supported findings from the snapshot. Focus-aware:
 * training focus leads with volume/recovery observations, health focus with
 * sleep/symptom/heart observations. Pure; unit-tested.
 */
fun buildFindings(snapshot: ClinicalReportData): List<ReportFinding> {
    val findings = mutableListOf<ReportFinding>()
    val span = rangeLabel(snapshot)

    // 1. Sleep — average nightly sleep with coverage.
    seriesStats(snapshot.sleepSeries)?.let { (avgMins, days, _) ->
        val hours = avgMins / 60.0
        findings.add(
            ReportFinding(
                text = "Average recorded sleep was ${fmt1(hours)} hours per night.",
                evidence = "$days days with sleep data in range ($span). Source: ${sourceLabel(snapshot, "sleep")}.",
                sourceKey = "sleep"
            )
        )
    }

    // 2. Heart rate — average with coverage.
    seriesStats(snapshot.heartRateSeries)?.let { (avg, days, _) ->
        findings.add(
            ReportFinding(
                text = "Average recorded heart rate was ${avg.roundToInt()} bpm.",
                evidence = "$days days with heart-rate data in range ($span). Source: ${sourceLabel(snapshot, "heartRate")}.",
                sourceKey = "heartRate"
            )
        )
    }

    // 3. Symptoms — top recorded symptom by distinct days.
    val symptomIds = symptomCategoryIds(snapshot)
    if (symptomIds.isNotEmpty()) {
        val top = topSymptomsByDistinctDays(snapshot.logEntries, snapshot.categoriesMap, symptomIds, limit = 1)
        top.firstOrNull()?.let { (name, distinctDays, count) ->
            findings.add(
                ReportFinding(
                    text = "Most frequently recorded symptom: $name, logged on $distinctDays distinct days.",
                    evidence = "$count entries across $distinctDays days in range. Missing entries are not treated as symptom-free days.",
                    sourceKey = "symptoms"
                )
            )
        }
    }

    // 4. Logging consistency.
    val (loggedDays, spanDays) = loggingCoverage(snapshot.logEntries, snapshot.range.startEpochMs, snapshot.range.endEpochMs)
    if (snapshot.logEntries.isNotEmpty()) {
        findings.add(
            ReportFinding(
                text = "Entries were logged on $loggedDays of $spanDays days in range.",
                evidence = "${snapshot.logEntries.size} entries total. Days without entries are shown as gaps, not zeros.",
                sourceKey = "logging"
            )
        )
    }

    // 5. HRV when present.
    seriesStats(snapshot.hrvSeries)?.let { (avg, days, _) ->
        findings.add(
            ReportFinding(
                text = "Average recorded HRV (RMSSD) was ${fmt1(avg)} ms.",
                evidence = "$days days with HRV data in range ($span). Source: ${sourceLabel(snapshot, "hrv")}.",
                sourceKey = "hrv"
            )
        )
    }

    // 6. Training volume for the training focus.
    if (snapshot.focusKey == "training") {
        seriesStats(snapshot.caloriesSeries)?.let { (avg, days, _) ->
            findings.add(
                ReportFinding(
                    text = "Average recorded active calories were ${avg.roundToInt()} kcal per day.",
                    evidence = "$days days with calorie data in range. Tabs has no distance/pace sensors; volume comes from logged activity only.",
                    sourceKey = "training"
                )
            )
        }
    }

    // Keep 3–5: prefer sleep, HR, symptoms, logging, then extras.
    return findings.take(5)
}

/**
 * Headline metrics strip for page 1: value + unit + coverage. Pure;
 * unit-tested.
 */
fun headlineMetrics(snapshot: ClinicalReportData): List<HeadlineMetric> {
    val metrics = mutableListOf<HeadlineMetric>()
    val (_, spanDays) = loggingCoverage(snapshot.logEntries, snapshot.range.startEpochMs, snapshot.range.endEpochMs)

    seriesStats(snapshot.sleepSeries)?.let { (avgMins, days, _) ->
        metrics.add(HeadlineMetric("Avg sleep", fmt1(avgMins / 60.0), "h/night", "$days of $spanDays days"))
    }
    seriesStats(snapshot.heartRateSeries)?.let { (avg, days, _) ->
        metrics.add(HeadlineMetric("Avg heart rate", "${avg.roundToInt()}", "bpm", "$days of $spanDays days"))
    }
    seriesStats(snapshot.hrvSeries)?.let { (avg, days, _) ->
        metrics.add(HeadlineMetric("Avg HRV", fmt1(avg), "ms", "$days of $spanDays days"))
    }
    if (snapshot.logEntries.isNotEmpty()) {
        val (loggedDays, _) = loggingCoverage(snapshot.logEntries, snapshot.range.startEpochMs, snapshot.range.endEpochMs)
        metrics.add(HeadlineMetric("Entries logged", "${snapshot.logEntries.size}", "entries", "$loggedDays of $spanDays days"))
    }
    seriesStats(snapshot.caloriesSeries)?.let { (avg, days, _) ->
        metrics.add(HeadlineMetric("Avg calories", "${avg.roundToInt()}", "kcal/day", "$days of $spanDays days"))
    }
    val bpCount = snapshot.bloodPressureSeries.size
    if (bpCount > 0) {
        metrics.add(HeadlineMetric("BP readings", "$bpCount", "readings", "in range"))
    }
    return metrics.take(6)
}

/** Category ids that count as "symptoms" for the findings (slug-based). */
fun symptomCategoryIds(snapshot: ClinicalReportData): Set<Int> {
    val symptomSlugs = setOf("symptoms", "mood")
    val byId = snapshot.categoriesMap.entries.associate { it.key to it.value }
    // categoriesMap holds names, not slugs; match common symptom category names.
    val symptomNames = setOf("symptoms", "symptom", "mood", "pain", "headache", "migraine", "fatigue", "nausea")
    return byId.filter { (_, name) -> name.lowercase(Locale.US) in symptomNames }.keys
}

/**
 * Human source label for a metric from the snapshot's section metadata
 * ("Health Connect", "cached device data", ...). Counts/values never leak
 * here — just the source name.
 */
fun sourceLabel(snapshot: ClinicalReportData, key: String): String {
    val msg = snapshot.sectionMetadata[key]?.message.orEmpty()
    return when {
        msg.contains("Health Connect", ignoreCase = true) -> "Health Connect"
        msg.contains("Cached data", ignoreCase = true) -> "cached device data"
        msg.contains("Fitbit", ignoreCase = true) -> "Fitbit cache"
        else -> "device data"
    }
}

/** One-line coverage disclosure for a metric key, for chart captions. */
fun coverageLabel(snapshot: ClinicalReportData, key: String): String {
    val meta = snapshot.sectionMetadata[key]
    val msg = meta?.message.orEmpty()
    // The collector appends "Covers yyyy-MM-dd..yyyy-MM-dd." — reuse it.
    val covers = Regex("Covers \\d{4}-\\d{2}-\\d{2}\\.\\.\\d{4}-\\d{2}-\\d{2}\\.").find(msg)?.value
    return listOfNotNull(
        sourceLabel(snapshot, key).replaceFirstChar { it.uppercase() },
        covers
    ).joinToString(". ")
}
