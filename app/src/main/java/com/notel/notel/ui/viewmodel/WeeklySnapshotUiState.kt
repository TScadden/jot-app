package com.notel.notel.ui.viewmodel

import com.notel.notel.data.model.WeeklySnapshotMetric
import com.notel.notel.data.repository.WeeklySnapshotMetricData

/**
 * Cohesive UI state for Weekly Snapshot ensuring selection never becomes ambiguous.
 */
data class WeeklySnapshotUiState(
    val selectedMetric: WeeklySnapshotMetric = WeeklySnapshotMetric.SLEEP_HOURS,
    val availableMetrics: List<WeeklySnapshotMetric> = listOf(
        WeeklySnapshotMetric.SLEEP_HOURS,
        WeeklySnapshotMetric.RESTING_HEART_RATE,
        WeeklySnapshotMetric.HR_SPIKES,
        WeeklySnapshotMetric.CALORIES,
        WeeklySnapshotMetric.LOGS,
        WeeklySnapshotMetric.HABIT_COMPLETION
    ),
    val metricData: WeeklySnapshotMetricData? = null,
    val isInitialLoading: Boolean = false,
    val isRefreshing: Boolean = false,
    val isStale: Boolean = false,
    val lastUpdatedMs: Long? = null,
    val errorMessage: String? = null,
    val emptyMessage: String? = null,
    val isPermissionRequired: Boolean = false,
    val isSourceUnavailable: Boolean = false
) {
    val displayTitle: String
        get() = selectedMetric.displayName
}
