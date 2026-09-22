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
