package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.dao.ScheduledDoseOccurrenceDao
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.HabitRepository
import com.notel.notel.data.repository.WeeklySnapshotMetricData
import com.notel.notel.data.repository.WeeklySnapshotRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.*
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
    data class Error(
        val message: String,
        val retainedData: WeeklySnapshotMetricData? = null
    ) : WeeklySnapshotState
}

@HiltViewModel
class WeeklySnapshotViewModel @Inject constructor(
    private val weeklySnapshotRepository: WeeklySnapshotRepository,
    private val preferences: NotelPreferences,
    private val healthConnectManager: HealthConnectManager,
    private val logEntryDao: LogEntryDao,
    private val scheduledDoseOccurrenceDao: ScheduledDoseOccurrenceDao,
    private val habitRepository: HabitRepository
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
        setupReactiveInvalidation()
    }

    fun checkBloodPressureAvailability() {
        viewModelScope.launch {
            val list = mutableListOf(
                "Sleep Hours",
                "Resting Heart Rate",
                "Calories",
                "Logs",
                "Symptoms",
                "Medication Adherence",
                "Habit Completion"
            )
            try {
                val hasBpPermission = healthConnectManager.hasBloodPressurePermission()
                if (hasBpPermission) {
                    val bpRecords = healthConnectManager.readBloodPressureRecords(days = 10)
                    if (bpRecords.isNotEmpty()) {
                        list.add("Blood Pressure")
                    }
                }
            } catch (e: Exception) {
                // Safeguard against Health Connect exceptions
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

    private fun setupReactiveInvalidation() {
        viewModelScope.launch {
            merge(
                logEntryDao.getAllEntries(),
                scheduledDoseOccurrenceDao.getOccurrencesForDate(""),
                habitRepository.habits
            ).collect {
                loadMetricData(currentMetric)
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
        checkBloodPressureAvailability()
        loadMetricData(currentMetric, isExplicitRefresh = true)
    }

    private fun loadMetricData(metric: String, isExplicitRefresh: Boolean = false) {
        val requestId = requestIdGenerator.incrementAndGet()
        loadJob?.cancel()

        val currentState = _uiState.value
        val retainedData = when (currentState) {
            is WeeklySnapshotState.Ready -> currentState.metricData
            is WeeklySnapshotState.Error -> currentState.retainedData
            else -> null
        }

        if (currentState is WeeklySnapshotState.Ready) {
            _uiState.value = currentState.copy(isRefreshing = true)
        } else if (!isExplicitRefresh && retainedData == null) {
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
                    _uiState.value = WeeklySnapshotState.Error(
                        message = e.message ?: "Failed to load snapshot data",
                        retainedData = retainedData
                    )
                }
            }
        }
    }
}
