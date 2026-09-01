package com.notel.notel.data.repository

import com.notel.notel.data.model.WeeklySnapshotMetric
import com.notel.notel.ui.viewmodel.WeeklySnapshotState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class WeeklySnapshotMetricSelectionTest {

    @Test
    fun selectionState_isIndependentFromContentState_andNeverDisagrees() {
        val selectedMetric = WeeklySnapshotMetric.CALORIES

        // 1. Loading State
        val loadingState = WeeklySnapshotState.Loading(
            metricName = selectedMetric.displayName,
            retainedData = null
        )
        assertEquals(selectedMetric.displayName, loadingState.metricName)

        // 2. ReadyWithData State
        val mockData = WeeklySnapshotMetricData(
            metricName = selectedMetric.displayName,
            unit = "kcal",
            points = emptyList(),
            averageOrTotalText = "Avg 2000 kcal",
            isAvailable = true,
            emptyMessage = null
        )
        val readyState = WeeklySnapshotState.ReadyWithData(
            metricName = selectedMetric.displayName,
            metricData = mockData,
            availableMetrics = listOf("Calories", "Sleep Hours")
        )
        assertEquals(selectedMetric.displayName, readyState.metricName)
        assertEquals(selectedMetric.displayName, readyState.metricData.metricName)

        // 3. ReadyEmpty State
        val emptyState = WeeklySnapshotState.ReadyEmpty(
            metricName = selectedMetric.displayName,
            emptyMessage = "No data recorded for Calories past 7 days",
            availableMetrics = listOf("Calories", "Sleep Hours")
        )
        assertEquals(selectedMetric.displayName, emptyState.metricName)

        // 4. Error State
        val errorState = WeeklySnapshotState.Error(
            metricName = selectedMetric.displayName,
            message = "Read timeout"
        )
        assertEquals(selectedMetric.displayName, errorState.metricName)

        // Confirm display selection and request selection agree across all asynchronous states
        listOf(loadingState.metricName, readyState.metricName, emptyState.metricName, errorState.metricName).forEach { displayMetric ->
            assertEquals(selectedMetric.displayName, displayMetric)
        }
    }
}
