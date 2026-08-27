package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.LogEntryDao
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
    data class ReadyWithData(
        val metricData: WeeklySnapshotMetricData,
        val availableMetrics: List<String>,
        val isRefreshing: Boolean = false
    ) : WeeklySnapshotState
    data class ReadyEmpty(
        val metricName: String,
        val emptyMessage: String,
        val availableMetrics: List<String>,
        val retainedData: WeeklySnapshotMetricData? = null,
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
    private val habitRepository: HabitRepository,
    private val timeProvider: com.notel.notel.util.TimeProvider
) : ViewModel() {

    private val _uiState = MutableStateFlow<WeeklySnapshotState>(WeeklySnapshotState.Loading)
    val uiState: StateFlow<WeeklySnapshotState> = _uiState.asStateFlow()

    val availableMetrics = MutableStateFlow<List<String>>(
        listOf(
            "Sleep Hours",
            "Resting Heart Rate",
            "HR Spikes",
            "Calories",
            "Logs",
            "Habit Completion"
        )
    )

    private val requestIdGenerator = AtomicLong(0)
    private var loadJob: Job? = null
    private var currentMetric: String = "Sleep Hours"
    private var lastHomeRefreshTimeMs: Long = 0L
    private val freshnessIntervalMs = 60_000L // 60s freshness interval

    init {
        checkBloodPressureAvailability()
        observeSelectedMetric()
        setupReactiveInvalidation()
    }

    fun onHomeActivated(forceFreshness: Boolean = false) {
        val now = System.currentTimeMillis()
        if (forceFreshness || (now - lastHomeRefreshTimeMs) > freshnessIntervalMs) {
            lastHomeRefreshTimeMs = now
            checkBloodPressureAvailability()
            loadMetricData(currentMetric, isExplicitRefresh = true)
        }
    }

    fun checkBloodPressureAvailability() {
        viewModelScope.launch {
            val list = mutableListOf(
                "Sleep Hours",
                "Resting Heart Rate",
                "HR Spikes",
                "Calories",
                "Logs",
                "Habit Completion"
            )
            var bpAvailable = false
            try {
                val hasBpPermission = healthConnectManager.hasBloodPressurePermission()
                if (hasBpPermission) {
                    val bpRecords = healthConnectManager.readBloodPressureRecords(days = 10)
                    if (bpRecords.isNotEmpty()) {
                        list.add("Blood Pressure")
                        bpAvailable = true
                    }
                }
            } catch (e: Exception) {
                // Safeguard against Health Connect exceptions
            }
            availableMetrics.value = list

            // Update visible ready state if present
            when (val currentState = _uiState.value) {
                is WeeklySnapshotState.ReadyWithData -> _uiState.value = currentState.copy(availableMetrics = list)
                is WeeklySnapshotState.ReadyEmpty -> _uiState.value = currentState.copy(availableMetrics = list)
                else -> {}
            }

            // Fallback if current metric is Blood Pressure but it is no longer available
            if (currentMetric == "Blood Pressure" && !bpAvailable) {
                selectMetric("Sleep Hours")
            }
        }
    }

    private fun observeSelectedMetric() {
        viewModelScope.launch {
            preferences.selectedWeeklySnapshotGraph
                .distinctUntilChanged()
                .collectLatest { metric ->
                    currentMetric = metric
                    loadMetricData(metric)
                }
        }
    }

    private fun setupReactiveInvalidation() {
        viewModelScope.launch {
            combine(
                logEntryDao.getAllEntries().distinctUntilChanged(),
                preferences.historicalHrSpikes.distinctUntilChanged(),
                habitRepository.habits,
                habitRepository.isInitialized
            ) { entries, spikes, habits, isInit ->
                val relevantChange = when (currentMetric) {
                    "Logs" -> true
                    "HR Spikes" -> true
                    "Habit Completion" -> true
                    else -> false
                }
                relevantChange
            }
            .filter { it }
            .collect {
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
        onHomeActivated(forceFreshness = true)
    }

    private fun loadMetricData(metric: String, isExplicitRefresh: Boolean = false) {
        val requestId = requestIdGenerator.incrementAndGet()
        loadJob?.cancel()

        val currentState = _uiState.value
        val retainedData = when (currentState) {
            is WeeklySnapshotState.ReadyWithData -> currentState.metricData
            is WeeklySnapshotState.ReadyEmpty -> currentState.retainedData
            is WeeklySnapshotState.Error -> currentState.retainedData
            else -> null
        }

        when (currentState) {
            is WeeklySnapshotState.ReadyWithData -> _uiState.value = currentState.copy(isRefreshing = true)
            is WeeklySnapshotState.ReadyEmpty -> _uiState.value = currentState.copy(isRefreshing = true)
            else -> {
                if (!isExplicitRefresh && retainedData == null) {
                    _uiState.value = WeeklySnapshotState.Loading
                }
            }
        }

        loadJob = viewModelScope.launch {
            try {
                val metricData = kotlinx.coroutines.withTimeout(5000L) {
                    weeklySnapshotRepository.get7DaySnapshot(metric)
                }
                if (requestId == requestIdGenerator.get()) {
                    val allNull = metricData.points.all { it.value == null }
                    if (!metricData.isAvailable || allNull) {
                        val msg = metricData.emptyMessage
                            ?: if (metric == "Sleep Hours") "No sleep data available for the past 7 days"
                            else "No data available past 7 days"
                        _uiState.value = WeeklySnapshotState.ReadyEmpty(
                            metricName = metric,
                            emptyMessage = msg,
                            availableMetrics = availableMetrics.value,
                            retainedData = retainedData,
                            isRefreshing = false
                        )
                    } else {
                        _uiState.value = WeeklySnapshotState.ReadyWithData(
                            metricData = metricData,
                            availableMetrics = availableMetrics.value,
                            isRefreshing = false
                        )
                    }
                }
            } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                if (requestId == requestIdGenerator.get()) {
                    _uiState.value = WeeklySnapshotState.Error(
                        message = "Request timed out while reading Health Connect. Tap refresh to retry.",
                        retainedData = retainedData
                    )
                }
            } catch (e: Exception) {
                if (requestId == requestIdGenerator.get()) {
                    _uiState.value = WeeklySnapshotState.Error(
                        message = "Failed to load snapshot data",
                        retainedData = retainedData
                    )
                }
            }
        }
    }
}
