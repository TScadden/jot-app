package com.notel.notel.data.model

import com.notel.notel.data.local.entity.LogEntry
import org.junit.Assert.*
import org.junit.Test

class ReportFindingsTest {

    private val dayMs = 24 * 60 * 60 * 1000L
    private val now = 1_790_496_000_000L

    private fun snapshot(
        sleep: List<Pair<String, Int>> = emptyList(),
        hr: List<Pair<String, Int>> = emptyList(),
        hrv: List<Pair<String, Double>> = emptyList(),
        calories: List<Pair<String, Int>> = emptyList(),
        entries: List<LogEntry> = emptyList(),
        categoriesMap: Map<Int, String> = emptyMap(),
        focusKey: String = "health",
        metadata: Map<String, SectionMetadata> = emptyMap()
    ) = ClinicalReportData(
        range = ClinicalReportRange(ClinicalReportRangeType.LAST_30_DAYS, now - 30 * dayMs, now, "UTC"),
        generationTimestamp = now,
        focusKey = focusKey,
        logEntries = entries,
        categoriesMap = categoriesMap,
        sleepSeries = sleep,
        heartRateSeries = hr,
        hrvSeries = hrv,
        caloriesSeries = calories,
        sectionMetadata = metadata
    )

    private fun meta(key: String, msg: String) =
        key to SectionMetadata(key, DataSourceStatus.SUCCESS, 10, msg)

    @Test
    fun buildFindings_sleepAndHrWithEvidence() {
        val s = snapshot(
            sleep = listOf("2026-09-20" to 420, "2026-09-21" to 480), // 7.0h, 8.0h -> avg 7.5h
            hr = listOf("2026-09-20" to 68, "2026-09-21" to 72),
            metadata = mapOf(
                meta("sleep", "Cached data Covers 2026-09-20..2026-09-21."),
                meta("heartRate", "Cached data Covers 2026-09-20..2026-09-21.")
            )
        )
        val findings = buildFindings(s)
        val sleepFinding = findings.firstOrNull { it.sourceKey == "sleep" }
        assertNotNull(sleepFinding)
        assertTrue(sleepFinding!!.text.contains("7.5 hours"))
        assertTrue(sleepFinding.evidence.contains("2 days with sleep data"))
        val hrFinding = findings.firstOrNull { it.sourceKey == "heartRate" }
        assertNotNull(hrFinding)
        assertTrue(hrFinding!!.text.contains("70 bpm"))
    }

    @Test
    fun buildFindings_sparseDataDoesNotInvent() {
        val s = snapshot()
        val findings = buildFindings(s)
        assertTrue(findings.isEmpty())
        assertTrue(headlineMetrics(s).isEmpty())
    }

    @Test
    fun buildFindings_capsAtFive() {
        val s = snapshot(
            sleep = listOf("2026-09-20" to 420),
            hr = listOf("2026-09-20" to 70),
            hrv = listOf("2026-09-20" to 42.0),
            calories = listOf("2026-09-20" to 2100),
            entries = listOf(LogEntry(id = 1, timestamp = now - dayMs, categoryId = 1, body = "headache")),
            categoriesMap = mapOf(1 to "Symptoms"),
            focusKey = "training"
        )
        val findings = buildFindings(s)
        assertTrue(findings.size <= 5)
        assertTrue(findings.size >= 3)
    }

    @Test
    fun buildFindings_topSymptomByDistinctDays() {
        val entries = listOf(
            LogEntry(id = 1, timestamp = now - dayMs, categoryId = 1, body = "a"),
            LogEntry(id = 2, timestamp = now - dayMs, categoryId = 1, body = "b"),
            LogEntry(id = 3, timestamp = now - 2 * dayMs, categoryId = 1, body = "c")
        )
        val s = snapshot(entries = entries, categoriesMap = mapOf(1 to "Symptoms"))
        val findings = buildFindings(s)
        val symptom = findings.firstOrNull { it.sourceKey == "symptoms" }
        assertNotNull(symptom)
        assertTrue(symptom!!.text.contains("Symptoms"))
        assertTrue(symptom.text.contains("2 distinct days"))
        // Honest about missing data.
        assertTrue(symptom.evidence.contains("not treated as symptom-free"))
    }

    @Test
    fun headlineMetrics_unitsAndCoverage() {
        val s = snapshot(
            sleep = listOf("2026-09-20" to 420, "2026-09-21" to 420),
            hr = listOf("2026-09-20" to 70)
        )
        val metrics = headlineMetrics(s)
        val sleep = metrics.firstOrNull { it.label == "Avg sleep" }
        assertNotNull(sleep)
        assertEquals("h/night", sleep!!.unit)
        assertTrue(sleep.coverage.contains("of 31 days"))
        val hr = metrics.firstOrNull { it.label == "Avg heart rate" }
        assertNotNull(hr)
        assertEquals("bpm", hr!!.unit)
    }

    @Test
    fun sourceLabel_mapsMetadataMessages() {
        val s = snapshot(
            metadata = mapOf(
                meta("sleep", "Health Connect sync Covers 2026-09-01..2026-09-30."),
                meta("heartRate", "Cached data Covers 2026-09-01..2026-09-30.")
            )
        )
        assertEquals("Health Connect", sourceLabel(s, "sleep"))
        assertEquals("cached device data", sourceLabel(s, "heartRate"))
        assertEquals("device data", sourceLabel(s, "hrv"))
    }
}
