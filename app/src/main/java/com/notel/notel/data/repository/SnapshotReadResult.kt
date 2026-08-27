package com.notel.notel.data.repository

import com.notel.notel.data.model.WeeklySnapshotMetric
import java.time.LocalDate

sealed interface SnapshotReadResult<out T> {
    data class Success<T>(
        val data: T,
        val coverageComplete: Boolean = true
    ) : SnapshotReadResult<T>

    data object NoData : SnapshotReadResult<Nothing>
    data object PermissionRequired : SnapshotReadResult<Nothing>
    data object SourceUnavailable : SnapshotReadResult<Nothing>
    data class Failure(val cause: Throwable) : SnapshotReadResult<Nothing>
}

data class MetricCacheKey(
    val metricKey: String,
    val rangeEndDate: LocalDate,
    val sourceStateTag: String = ""
)

data class WeeklySnapshotCacheEntry(
    val key: MetricCacheKey,
    val metricData: WeeklySnapshotMetricData,
    val timestampMs: Long,
    val readClassification: String, // "SUCCESS", "NO_DATA", "PARTIAL", "PERMISSION_REQUIRED", "SOURCE_UNAVAILABLE", "FAILURE"
    val startDate: LocalDate,
    val endDate: LocalDate
)
