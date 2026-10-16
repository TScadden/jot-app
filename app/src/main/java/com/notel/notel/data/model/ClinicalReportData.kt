package com.notel.notel.data.model

import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.data.healthconnect.BloodPressureUiRecord

enum class ClinicalReportRangeType {
    FULL,
    LAST_30_DAYS
}

data class ClinicalReportRange(
    val type: ClinicalReportRangeType,
    val startEpochMs: Long,
    val endEpochMs: Long
) {
    val durationDays: Int
        get() = ((endEpochMs - startEpochMs) / (24 * 60 * 60 * 1000L)).toInt().coerceAtLeast(1)
}

enum class DataSourceStatus {
    SUCCESS,
    NO_DATA,
    PERMISSION_DENIED,
    UNAVAILABLE,
    TIMED_OUT,
    ERROR
}

data class SectionMetadata(
    val sectionKey: String,
    val status: DataSourceStatus,
    val recordCount: Int = 0,
    val message: String? = null
)

data class ClinicalReportData(
    val range: ClinicalReportRange,
    val generationTimestamp: Long = System.currentTimeMillis(),
    val logEntries: List<LogEntry> = emptyList(),
    val categoriesMap: Map<Int, String> = emptyMap(),
    val userContext: String = "",
    val userAge: Int = 0,
    val userHeight: Float = 0f,
    val userWeight: Float = 0f,
    val userGender: String = "",
    val conditions: List<String> = emptyList(),
    val medications: List<Medication> = emptyList(),
    val knowledgeDocuments: List<String> = emptyList(),
    val heartRateSeries: List<Pair<String, Int>> = emptyList(),
    val sleepSeries: List<Pair<String, Int>> = emptyList(),
    val deepSleepSeries: List<Pair<String, Int>> = emptyList(),
    val caloriesSeries: List<Pair<String, Int>> = emptyList(),
    val hrvSeries: List<Pair<String, Double>> = emptyList(),
    val heartRateSpikes: List<DailyHeartRateSummary> = emptyList(),
    val bloodPressureSeries: List<BloodPressureUiRecord> = emptyList(),
    val bodyLoadHistory: String = "",
    val sectionMetadata: Map<String, SectionMetadata> = emptyMap()
) {
    /**
     * Actual covered date range for heart rate, derived from the series the
     * report really holds — NOT the nominal report range. Dates are
     * yyyy-MM-dd, so lexicographic min/max is chronological. Zero values are
     * failed reads, never data, so they do not extend the covered range.
     * Null when there is no heart-rate data at all.
     */
    val heartRateCoveredStartDate: String?
        get() = heartRateSeries.filter { it.second > 0 }.map { it.first }.minOrNull()

    val heartRateCoveredEndDate: String?
        get() = heartRateSeries.filter { it.second > 0 }.map { it.first }.maxOrNull()

    /** Actual covered date range for the per-day HR spike summaries. */
    val hrSpikesCoveredStartDate: String?
        get() = heartRateSpikes.map { it.date }.minOrNull()

    val hrSpikesCoveredEndDate: String?
        get() = heartRateSpikes.map { it.date }.maxOrNull()

    val hasAnyData: Boolean
        get() = logEntries.isNotEmpty() ||
                heartRateSeries.isNotEmpty() ||
                sleepSeries.isNotEmpty() ||
                caloriesSeries.isNotEmpty() ||
                hrvSeries.isNotEmpty() ||
                heartRateSpikes.isNotEmpty() ||
                bloodPressureSeries.isNotEmpty() ||
                conditions.isNotEmpty() ||
                medications.isNotEmpty() ||
                knowledgeDocuments.isNotEmpty()
}
