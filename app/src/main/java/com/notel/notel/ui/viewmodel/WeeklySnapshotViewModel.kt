package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.DailySnapshotPoint
import com.notel.notel.data.repository.WeeklySnapshotMetricData
import com.notel.notel.data.repository.WeeklySnapshotRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject

sealed interface WeeklySnapshotState {
    object Loading : WeeklySnapshotState
    data class Ready(
        val metricData: WeeklySnapshotMetricData,
        val availableMetrics: List<String>,
        val isRefreshing: Boolean = false
    ) : WeeklySnapshotState
    data class Error(val message: String) : WeeklySnapshotState
}

@HiltViewModel
class WeeklySnapshotViewModel @Inject constructor(
    private val weeklySnapshotRepository: WeeklySnapshotRepository,
    private val preferences: NotelPreferences,
    private val healthConnectManager: HealthConnectManager
) : ViewModel() {

    private val _uiState = MutableStateFlow<WeeklySnapshotState>(WeeklySnapshotState.Loading)
    val uiState: StateFlow<WeeklySnapshotState> = _uiState.asStateFlow()

    val availableMetrics = MutableStateFlow<List<String>>(
        listOf(
            "Sleep Hours",
            "Resting Heart Rate",
            "Calories",
            "Logs",
            "Symptoms",
            "Medication Adherence",
            "Habit Completion"
        )
    )

    private val requestIdGenerator = AtomicLong(0)
    private var loadJob: Job? = null
    private var currentMetric: String = "Sleep Hours"

    init {
        checkBloodPressureAvailability()
        observeSelectedMetric()
    }

    fun checkBloodPressureAvailability() {
        viewModelScope.launch {
            val hasBpPermission = healthConnectManager.hasBloodPressurePermission()
            val bpRecords = if (hasBpPermission) healthConnectManager.readBloodPressureRecords(days = 10) else emptyList()
            val list = mutableListOf(
                "Sleep Hours",
                "Resting Heart Rate",
                "Calories",
                "Logs",
                "Symptoms",
                "Medication Adherence",
                "Habit Completion"
            )
            if (hasBpPermission && bpRecords.isNotEmpty()) {
                list.add("Blood Pressure")
            }
            availableMetrics.value = list
        }
    }

    private fun observeSelectedMetric() {
        viewModelScope.launch {
            preferences.selectedWeeklySnapshotGraph.collectLatest { metric ->
                currentMetric = metric
                loadMetricData(metric)
            }
        }
    }

    fun selectMetric(metric: String) {
        if (metric == currentMetric) return
        viewModelScope.launch {
            preferences.setSelectedWeeklySnapshotGraph(metric)
        }
    }

    fun refresh() {
        loadMetricData(currentMetric, isExplicitRefresh = true)
    }

    private fun loadMetricData(metric: String, isExplicitRefresh: Boolean = false) {
        val requestId = requestIdGenerator.incrementAndGet()
        loadJob?.cancel()

        val currentState = _uiState.value
        if (currentState is WeeklySnapshotState.Ready) {
            _uiState.value = currentState.copy(isRefreshing = true)
        } else if (!isExplicitRefresh) {
            _uiState.value = WeeklySnapshotState.Loading
        }

        loadJob = viewModelScope.launch {
            try {
                val metricData = weeklySnapshotRepository.get7DaySnapshot(metric)
                if (requestId == requestIdGenerator.get()) {
                    _uiState.value = WeeklySnapshotState.Ready(
                        metricData = metricData,
                        availableMetrics = availableMetrics.value,
                        isRefreshing = false
                    )
                }
            } catch (e: Exception) {
                if (requestId == requestIdGenerator.get()) {
                    if (currentState is WeeklySnapshotState.Ready) {
                        _uiState.value = currentState.copy(isRefreshing = false)
                    } else {
                        _uiState.value = WeeklySnapshotState.Error(e.message ?: "Failed to load snapshot data")
                    }
                }
            }
        }
    }
}
