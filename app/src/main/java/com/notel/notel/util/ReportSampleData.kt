package com.notel.notel.util

import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.model.*
import java.time.LocalDate
import java.time.ZoneId
import kotlin.random.Random

/**
 * Clearly-marked SYNTHETIC sample report data (Phase 2, Lab only).
 *
 * The founder renders these on-device to review the PDF layout. Every
 * sample is deterministic (seeded RNG), uses fake names ("Medication A",
 * "Sample User"), carries focusText "SYNTHETIC SAMPLE", and is rendered
 * with [ReportRenderOptions.synthetic] so every page is watermarked
 * "SYNTHETIC SAMPLE — NOT REAL DATA". Never built from real user data.
 */
object ReportSampleData {

    private val zone = ZoneId.of("America/Denver")
    private const val DAY_MS = 24 * 60 * 60 * 1000L

    private val sampleCategories = mapOf(
        1 to "Symptoms",
        2 to "Medication",
        3 to "Sleep",
        4 to "Mood",
        5 to "Heart Rate",
        6 to "Personal",
        7 to "Calories"
    )

    data class Sample(val key: String, val title: String, val data: ClinicalReportData)

    fun buildSamples(nowMs: Long = System.currentTimeMillis()): List<Sample> = listOf(
        Sample("health-30d", "Health · 30 days", health30d(nowMs)),
        Sample("training-30d", "Training · 30 days", training30d(nowMs)),
        Sample("custom-sparse", "Custom · sparse", customSparse(nowMs)),
        Sample("health-2y", "Health · 2-year history", healthLongHistory(nowMs))
    )

    /** Canned AI-style narrative for the samples, clearly synthetic. */
    fun syntheticSummary(title: String): String = """
[SECTION] SYNTHETIC SAMPLE SUMMARY
[BOLD]Notice:[BOLD] This is a [BOLD]synthetic sample report[BOLD] generated for layout review. All names, values, dates, and events are fabricated and do not represent any real person.

[SECTION] WHAT THIS SAMPLE SHOWS
[BULLET]Deterministic fabricated metrics with realistic gaps, so missing-data rendering can be inspected.
[BULLET]Recorded medication changes with before/after comparisons in correlation-only language.
[BULLET]Section toggles and your-note overlays apply to this layout exactly as they do to real reports.

[SECTION] SAMPLE: $title
[BULLET]Fabricated sleep, heart-rate, and symptom series with seeded randomness.
[BULLET]Medication A started on a recorded date; a dose mention was extracted from fabricated log text.
""".trimIndent()

    // ── Builders ──

    private fun health30d(nowMs: Long): ClinicalReportData {
        val rnd = Random(42)
        val today = LocalDate.now(zone)
        val start = today.minusDays(29)
        val sleep = mutableListOf<Pair<String, Int>>()
        val hr = mutableListOf<Pair<String, Int>>()
        val hrv = mutableListOf<Pair<String, Double>>()
        val entries = mutableListOf<LogEntry>()
        var id = 1L
        for (d in 0 until 30) {
            val date = start.plusDays(d.toLong())
            val key = date.toString()
            // ~15% missing days — gaps must render as gaps.
            if (rnd.nextDouble() > 0.15) {
                sleep.add(key to (360 + rnd.nextInt(180)))
                hr.add(key to (62 + rnd.nextInt(16)))
                hrv.add(key to (35 + rnd.nextDouble() * 25))
            }
            // Symptom entries on ~40% of days.
            if (rnd.nextDouble() < 0.4) {
                val symptom = listOf("Headache", "Nausea", "Fatigue").random(rnd)
                entries.add(
                    LogEntry(
                        id = id++,
                        timestamp = date.atStartOfDay(zone).toInstant().toEpochMilli() + rnd.nextLong(8 * 3600_000L, 20 * 3600_000L),
                        categoryId = 1,
                        body = "Sample log: $symptom severity ${1 + rnd.nextInt(5)}/5 (synthetic)"
                    )
                )
            }
        }
        // Medication start with a real parseable date + a dose mention in logs.
        val meds = listOf(
            Medication(name = "Medication A", dose = "10mg", frequency = "Daily", startedDate = start.plusDays(9).toString()),
            Medication(name = "Medication B", dose = "5mg", frequency = "Twice daily", startedDate = start.plusDays(2).toString(), endedDate = start.plusDays(19).toString())
        )
        entries.add(
            LogEntry(
                id = id++,
                timestamp = start.plusDays(20).atStartOfDay(zone).toInstant().toEpochMilli() + 12 * 3600_000L,
                categoryId = 2,
                body = "Sample note: clinician increased Medication A to 20mg (synthetic mention)"
            )
        )
        return base(
            nowMs = nowMs,
            rangeType = ClinicalReportRangeType.LAST_30_DAYS,
            startMs = start.atStartOfDay(zone).toInstant().toEpochMilli(),
            endMs = nowMs,
            focusKey = "health",
            entries = entries,
            meds = meds,
            sleep = sleep, hr = hr, hrv = hrv
        )
    }

    private fun training30d(nowMs: Long): ClinicalReportData {
        val rnd = Random(7)
        val today = LocalDate.now(zone)
        val start = today.minusDays(29)
        val calories = mutableListOf<Pair<String, Int>>()
        val hr = mutableListOf<Pair<String, Int>>()
        val sleep = mutableListOf<Pair<String, Int>>()
        val entries = mutableListOf<LogEntry>()
        var id = 1L
        for (d in 0 until 30) {
            val date = start.plusDays(d.toLong())
            val key = date.toString()
            val trained = rnd.nextDouble() < 0.55
            if (rnd.nextDouble() > 0.1) {
                sleep.add(key to (380 + rnd.nextInt(140)))
                hr.add(key to (58 + rnd.nextInt(14)))
            }
            if (trained) {
                calories.add(key to (400 + rnd.nextInt(700)))
                entries.add(
                    LogEntry(
                        id = id++,
                        timestamp = date.atStartOfDay(zone).toInstant().toEpochMilli() + 18 * 3600_000L,
                        categoryId = 6,
                        body = "Sample training log: evening session, RPE ${1 + rnd.nextInt(10)}/10 (synthetic)"
                    )
                )
            }
        }
        return base(
            nowMs = nowMs,
            rangeType = ClinicalReportRangeType.LAST_30_DAYS,
            startMs = start.atStartOfDay(zone).toInstant().toEpochMilli(),
            endMs = nowMs,
            focusKey = "training",
            entries = entries,
            meds = emptyList(),
            sleep = sleep, hr = hr, calories = calories
        )
    }

    private fun customSparse(nowMs: Long): ClinicalReportData {
        val today = LocalDate.now(zone)
        val start = today.minusDays(29)
        val entries = listOf(
            LogEntry(id = 1, timestamp = start.plusDays(3).atStartOfDay(zone).toInstant().toEpochMilli(), categoryId = 1, body = "Sample sparse log one (synthetic)"),
            LogEntry(id = 2, timestamp = start.plusDays(11).atStartOfDay(zone).toInstant().toEpochMilli(), categoryId = 4, body = "Sample sparse log two (synthetic)"),
            LogEntry(id = 3, timestamp = start.plusDays(24).atStartOfDay(zone).toInstant().toEpochMilli(), categoryId = 1, body = "Sample sparse log three (synthetic)")
        )
        return base(
            nowMs = nowMs,
            rangeType = ClinicalReportRangeType.LAST_30_DAYS,
            startMs = start.atStartOfDay(zone).toInstant().toEpochMilli(),
            endMs = nowMs,
            focusKey = "custom",
            entries = entries,
            meds = emptyList()
        ).copy(focusText = "synthetic sparse custom focus")
    }

    private fun healthLongHistory(nowMs: Long): ClinicalReportData {
        val rnd = Random(99)
        val today = LocalDate.now(zone)
        val start = today.minusDays(729) // ~2 years
        val sleep = mutableListOf<Pair<String, Int>>()
        val hr = mutableListOf<Pair<String, Int>>()
        val entries = mutableListOf<LogEntry>()
        var id = 1L
        // One point every ~3 days keeps it light while still spanning 2 years.
        var d = 0L
        while (d < 730) {
            val date = start.plusDays(d)
            val key = date.toString()
            if (rnd.nextDouble() > 0.25) {
                // Slow drift over two years + noise: exercises monthly aggregation.
                val drift = (d / 730.0) * 40
                sleep.add(key to (400 + drift.toInt() + rnd.nextInt(-60, 61)))
                hr.add(key to (70 - (d / 730.0 * 6).toInt() + rnd.nextInt(-5, 6)))
            }
            if (rnd.nextDouble() < 0.08) {
                entries.add(
                    LogEntry(
                        id = id++,
                        timestamp = date.atStartOfDay(zone).toInstant().toEpochMilli() + 12 * 3600_000L,
                        categoryId = 1,
                        body = "Sample historical log (synthetic)"
                    )
                )
            }
            d += 3
        }
        val meds = listOf(
            Medication(name = "Medication A", dose = "10mg", frequency = "Daily", startedDate = start.plusDays(200).toString())
        )
        return base(
            nowMs = nowMs,
            rangeType = ClinicalReportRangeType.FULL,
            startMs = 0L,
            endMs = nowMs,
            focusKey = "health",
            entries = entries,
            meds = meds,
            sleep = sleep, hr = hr
        )
    }

    private fun base(
        nowMs: Long,
        rangeType: ClinicalReportRangeType,
        startMs: Long,
        endMs: Long,
        focusKey: String,
        entries: List<LogEntry>,
        meds: List<Medication>,
        sleep: List<Pair<String, Int>> = emptyList(),
        hr: List<Pair<String, Int>> = emptyList(),
        hrv: List<Pair<String, Double>> = emptyList(),
        calories: List<Pair<String, Int>> = emptyList()
    ): ClinicalReportData {
        fun meta(key: String, n: Int) =
            key to SectionMetadata(key, if (n > 0) DataSourceStatus.SUCCESS else DataSourceStatus.NO_DATA, n, "Synthetic sample data")
        return ClinicalReportData(
            range = ClinicalReportRange(rangeType, startMs, endMs, zone.id),
            generationTimestamp = nowMs,
            focusKey = focusKey,
            focusText = "SYNTHETIC SAMPLE — not real data",
            logEntries = entries,
            categoriesMap = sampleCategories,
            userContext = "Synthetic sample profile",
            userAge = 30,
            userGender = "Sample",
            conditions = listOf("Sample Condition Alpha"),
            medications = meds,
            heartRateSeries = hr,
            sleepSeries = sleep,
            hrvSeries = hrv,
            caloriesSeries = calories,
            sectionMetadata = mapOf(
                meta("logs", entries.size),
                meta("sleep", sleep.size),
                meta("heartRate", hr.size),
                meta("hrv", hrv.size),
                meta("calories", calories.size),
                meta("medications", meds.size),
                meta("conditions", 1)
            )
        )
    }
}
