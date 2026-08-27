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
    private var lastHomeRefreshDate: java.time.LocalDate? = null
    private val freshnessIntervalMs = 60_000L // 60s freshness interval
    private var isInitialized = false

    init {
        checkBloodPressureAvailability()
        observeSelectedMetric()
        setupSourceSpecificReactiveInvalidation()
    }

    fun onHomeActivated(forceFreshness: Boolean = false) {
        val nowMs = timeProvider.nowEpochMilli()
        val todayDate = timeProvider.today()
        val dateChanged = lastHomeRefreshDate != null && lastHomeRefreshDate != todayDate
        val expired = (nowMs - lastHomeRefreshTimeMs) > freshnessIntervalMs

        if (!isInitialized || forceFreshness || dateChanged || expired) {
            isInitialized = true
            lastHomeRefreshTimeMs = nowMs
            lastHomeRefreshDate = todayDate
            checkBloodPressureAvailability()
            loadMetricData(currentMetric, isExplicitRefresh = forceFreshness)
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
                    val metricChanged = metric != currentMetric
                    if (metricChanged) {
                        currentMetric = metric
                        loadMetricData(metric)
                    } else if (!isInitialized) {
                        onHomeActivated(forceFreshness = false)
                    }
                }
        }
    }

    private fun setupSourceSpecificReactiveInvalidation() {
        // Logs observer
        viewModelScope.launch {
            logEntryDao.getAllEntries()
                .drop(1)
                .distinctUntilChanged()
                .debounce(300L)
                .collect {
                    if (currentMetric == "Logs") {
                        loadMetricData("Logs")
                    }
                }
        }

        // HR Spikes observer
        viewModelScope.launch {
            preferences.historicalHrSpikes
                .drop(1)
                .distinctUntilChanged()
                .debounce(300L)
                .collect {
                    if (currentMetric == "HR Spikes") {
                        loadMetricData("HR Spikes")
                    }
                }
        }

        // Habit Completion observer
        viewModelScope.launch {
            combine(
                habitRepository.habits,
                habitRepository.isInitialized
            ) { habits, isInit -> Pair(habits, isInit) }
                .drop(1)
                .distinctUntilChanged()
                .debounce(300L)
                .collect {
                    if (currentMetric == "Habit Completion") {
                        loadMetricData("Habit Completion")
                    }
                }
        }
    }

    fun selectMetric(metric: String) {
        if (metric == currentMetric) return
        currentMetric = metric
        loadMetricData(metric)
        viewModelScope.launch {
            preferences.setSelectedWeeklySnapshotGraph(metric)
        }
    }

    fun refresh() {
        val currentState = _uiState.value
        val isCurrentlyRefreshing = when (currentState) {
            is WeeklySnapshotState.ReadyWithData -> currentState.isRefreshing
            is WeeklySnapshotState.ReadyEmpty -> currentState.isRefreshing
            is WeeklySnapshotState.Loading -> true
            else -> false
        }
        if (isCurrentlyRefreshing) return
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

        val isMetricSwitch = retainedData?.metricName != metric

        when {
            isMetricSwitch -> {
                _uiState.value = WeeklySnapshotState.Loading
            }
            currentState is WeeklySnapshotState.ReadyWithData -> {
                _uiState.value = currentState.copy(isRefreshing = true)
            }
            currentState is WeeklySnapshotState.ReadyEmpty -> {
                _uiState.value = currentState.copy(isRefreshing = true)
            }
            else -> {
                if (!isExplicitRefresh && retainedData == null) {
                    _uiState.value = WeeklySnapshotState.Loading
                }
            }
        }

        loadJob = viewModelScope.launch {
            try {
                val metricData = kotlinx.coroutines.withTimeout(5000L) {
                    weeklySnapshotRepository.get7DaySnapshot(metric, targetToday = timeProvider.today())
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
