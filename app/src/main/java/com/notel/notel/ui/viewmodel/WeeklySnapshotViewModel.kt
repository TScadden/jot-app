package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.model.WeeklySnapshotMetric
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.HabitRepository
import com.notel.notel.data.repository.SnapshotReadResult
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

    private val _newUiState = MutableStateFlow(WeeklySnapshotUiState())
    val snapshotUiState: StateFlow<WeeklySnapshotUiState> = _newUiState.asStateFlow()

    val availableMetrics = MutableStateFlow<List<String>>(
        listOf(
            WeeklySnapshotMetric.SLEEP_HOURS.displayName,
            WeeklySnapshotMetric.RESTING_HEART_RATE.displayName,
            WeeklySnapshotMetric.HR_SPIKES.displayName,
            WeeklySnapshotMetric.CALORIES.displayName,
            WeeklySnapshotMetric.LOGS.displayName,
            WeeklySnapshotMetric.HABIT_COMPLETION.displayName
        )
    )

    private val requestIdGenerator = AtomicLong(0)
    private var loadJob: Job? = null
    private var currentMetric: WeeklySnapshotMetric = WeeklySnapshotMetric.SLEEP_HOURS
    private var lastHomeRefreshTimeMs: Long = 0L
    private var lastHomeRefreshDate: java.time.LocalDate? = null
    private val freshnessIntervalMs = 60_000L // 60s freshness interval
    private var isInitialized = false

    // Single source of truth for ignoring local preference echoes
    private var pendingPersistedMetric: WeeklySnapshotMetric? = null

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
            loadMetricDataTyped(currentMetric, isExplicitRefresh = forceFreshness)
        }
    }

    fun checkBloodPressureAvailability() {
        viewModelScope.launch {
            val list = mutableListOf(
                WeeklySnapshotMetric.SLEEP_HOURS,
                WeeklySnapshotMetric.RESTING_HEART_RATE,
                WeeklySnapshotMetric.HR_SPIKES,
                WeeklySnapshotMetric.CALORIES,
                WeeklySnapshotMetric.LOGS,
                WeeklySnapshotMetric.HABIT_COMPLETION
            )
            var bpAvailable = false
            try {
                val hasBpPermission = healthConnectManager.hasBloodPressurePermission()
                if (hasBpPermission) {
                    val bpRecords = healthConnectManager.readBloodPressureRecords(days = 10)
                    if (bpRecords.isNotEmpty()) {
                        list.add(WeeklySnapshotMetric.BLOOD_PRESSURE)
                        bpAvailable = true
                    }
                }
            } catch (e: Exception) {
                // Safeguard against Health Connect exceptions
            }
            val displayNames = list.map { it.displayName }
            availableMetrics.value = displayNames
            _newUiState.update { it.copy(availableMetrics = list) }

            // Update visible legacy state if present
            when (val currentState = _uiState.value) {
                is WeeklySnapshotState.ReadyWithData -> _uiState.value = currentState.copy(availableMetrics = displayNames)
                is WeeklySnapshotState.ReadyEmpty -> _uiState.value = currentState.copy(availableMetrics = displayNames)
                else -> {}
            }

            // Fallback if current metric is Blood Pressure but it is no longer available
            if (currentMetric == WeeklySnapshotMetric.BLOOD_PRESSURE && !bpAvailable) {
                selectMetricTyped(WeeklySnapshotMetric.SLEEP_HOURS)
            }
        }
    }

    private fun observeSelectedMetric() {
        viewModelScope.launch {
            preferences.selectedWeeklySnapshotMetric
                .distinctUntilChanged()
                .collectLatest { metric ->
                    // Ignore echoed emission if it matches what we just selected locally
                    if (pendingPersistedMetric == metric) {
                        pendingPersistedMetric = null
                        return@collectLatest
                    }
                    val metricChanged = metric != currentMetric
                    if (metricChanged) {
                        currentMetric = metric
                        loadMetricDataTyped(metric)
                    } else if (!isInitialized) {
                        onHomeActivated(forceFreshness = false)
                    }
                }
        }
    }

    private fun setupSourceSpecificReactiveInvalidation() {
        viewModelScope.launch {
            logEntryDao.getAllEntries()
                .drop(1)
                .distinctUntilChanged()
                .debounce(300L)
                .collect {
                    if (currentMetric == WeeklySnapshotMetric.LOGS) {
                        loadMetricDataTyped(WeeklySnapshotMetric.LOGS, isExplicitRefresh = true)
                    }
                }
        }

        viewModelScope.launch {
            preferences.historicalHrSpikes
                .drop(1)
                .distinctUntilChanged()
                .debounce(300L)
                .collect {
                    if (currentMetric == WeeklySnapshotMetric.HR_SPIKES) {
                        loadMetricDataTyped(WeeklySnapshotMetric.HR_SPIKES, isExplicitRefresh = true)
                    }
                }
        }

        viewModelScope.launch {
            combine(
                habitRepository.habits,
                habitRepository.isInitialized
            ) { habits, isInit -> Pair(habits, isInit) }
                .drop(1)
                .distinctUntilChanged()
                .debounce(300L)
                .collect {
                    if (currentMetric == WeeklySnapshotMetric.HABIT_COMPLETION) {
                        loadMetricDataTyped(WeeklySnapshotMetric.HABIT_COMPLETION, isExplicitRefresh = true)
                    }
                }
        }
    }

    fun selectMetric(metricName: String) {
        val metric = WeeklySnapshotMetric.fromKeyOrDisplayName(metricName)
        selectMetricTyped(metric)
    }

    fun selectMetricTyped(metric: WeeklySnapshotMetric) {
        if (metric == currentMetric && _uiState.value !is WeeklySnapshotState.Loading) return
        currentMetric = metric
        pendingPersistedMetric = metric

        // Instantly serve cached data if available (<100ms target)
        val cached = weeklySnapshotRepository.getCachedSnapshot(metric, targetToday = timeProvider.today())
        if (cached != null) {
            val allNull = cached.points.all { it.value == null }
            if (allNull) {
                val msg = cached.emptyMessage ?: "No data available past 7 days"
                _uiState.value = WeeklySnapshotState.ReadyEmpty(
                    metricName = metric.displayName,
                    emptyMessage = msg,
                    availableMetrics = availableMetrics.value,
                    retainedData = cached,
                    isRefreshing = false
                )
            } else {
                _uiState.value = WeeklySnapshotState.ReadyWithData(
                    metricData = cached,
                    availableMetrics = availableMetrics.value,
                    isRefreshing = false
                )
            }
            _newUiState.update {
                it.copy(
                    selectedMetric = metric,
                    metricData = cached,
                    isInitialLoading = false,
                    isRefreshing = false,
                    emptyMessage = if (allNull) cached.emptyMessage ?: "No data available past 7 days" else null,
                    errorMessage = null
                )
            }
        }

        loadMetricDataTyped(metric)

        viewModelScope.launch {
            preferences.setSelectedWeeklySnapshotMetric(metric)
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

    private fun loadMetricDataTyped(metric: WeeklySnapshotMetric, isExplicitRefresh: Boolean = false) {
        val requestId = requestIdGenerator.incrementAndGet()
        loadJob?.cancel()

        val cached = weeklySnapshotRepository.getCachedSnapshot(metric, targetToday = timeProvider.today())
        val isCachedHit = cached != null

        val currentState = _uiState.value
        val retainedData = cached ?: when (currentState) {
            is WeeklySnapshotState.ReadyWithData -> currentState.metricData
            is WeeklySnapshotState.ReadyEmpty -> currentState.retainedData
            is WeeklySnapshotState.Error -> currentState.retainedData
            else -> null
        }

        if (!isCachedHit) {
            _uiState.value = WeeklySnapshotState.Loading
            _newUiState.update { it.copy(selectedMetric = metric, isInitialLoading = true, errorMessage = null) }
        } else if (isExplicitRefresh) {
            when (currentState) {
                is WeeklySnapshotState.ReadyWithData -> _uiState.value = currentState.copy(isRefreshing = true)
                is WeeklySnapshotState.ReadyEmpty -> _uiState.value = currentState.copy(isRefreshing = true)
                else -> {}
            }
            _newUiState.update { it.copy(selectedMetric = metric, isRefreshing = true) }
        }

        loadJob = viewModelScope.launch {
            try {
                val result = kotlinx.coroutines.withTimeout(5000L) {
                    weeklySnapshotRepository.get7DaySnapshotTyped(
                        metric = metric,
                        targetToday = timeProvider.today(),
                        forceRefresh = isExplicitRefresh
                    )
                }

                if (requestId == requestIdGenerator.get()) {
                    when (result) {
                        is SnapshotReadResult.Success -> {
                            val metricData = result.data
                            val allNull = metricData.points.all { it.value == null }
                            if (!metricData.isAvailable || allNull) {
                                val msg = metricData.emptyMessage
                                    ?: if (metric == WeeklySnapshotMetric.SLEEP_HOURS) "No sleep data available for the past 7 days"
                                    else "No data available past 7 days"
                                _uiState.value = WeeklySnapshotState.ReadyEmpty(
                                    metricName = metric.displayName,
                                    emptyMessage = msg,
                                    availableMetrics = availableMetrics.value,
                                    retainedData = retainedData,
                                    isRefreshing = false
                                )
                                _newUiState.update {
                                    it.copy(
                                        selectedMetric = metric,
                                        metricData = metricData,
                                        isInitialLoading = false,
                                        isRefreshing = false,
                                        emptyMessage = msg,
                                        errorMessage = null
                                    )
                                }
                            } else {
                                _uiState.value = WeeklySnapshotState.ReadyWithData(
                                    metricData = metricData,
                                    availableMetrics = availableMetrics.value,
                                    isRefreshing = false
                                )
                                _newUiState.update {
                                    it.copy(
                                        selectedMetric = metric,
                                        metricData = metricData,
                                        isInitialLoading = false,
                                        isRefreshing = false,
                                        emptyMessage = null,
                                        errorMessage = null,
                                        lastUpdatedMs = System.currentTimeMillis()
                                    )
                                }
                            }
                        }
                        is SnapshotReadResult.PermissionRequired -> {
                            _uiState.value = WeeklySnapshotState.ReadyEmpty(
                                metricName = metric.displayName,
                                emptyMessage = "${metric.displayName} permission not granted",
                                availableMetrics = availableMetrics.value,
                                retainedData = retainedData,
                                isRefreshing = false
                            )
                            _newUiState.update {
                                it.copy(
                                    selectedMetric = metric,
                                    isInitialLoading = false,
                                    isRefreshing = false,
                                    isPermissionRequired = true,
                                    emptyMessage = "${metric.displayName} permission not granted"
                                )
                            }
                        }
                        is SnapshotReadResult.SourceUnavailable, is SnapshotReadResult.NoData -> {
                            _uiState.value = WeeklySnapshotState.ReadyEmpty(
                                metricName = metric.displayName,
                                emptyMessage = "No data available for ${metric.displayName}",
                                availableMetrics = availableMetrics.value,
                                retainedData = retainedData,
                                isRefreshing = false
                            )
                            _newUiState.update {
                                it.copy(
                                    selectedMetric = metric,
                                    isInitialLoading = false,
                                    isRefreshing = false,
                                    emptyMessage = "No data available for ${metric.displayName}"
                                )
                            }
                        }
                        is SnapshotReadResult.Failure -> {
                            val errMsg = result.cause.message ?: "Failed to read data"
                            _uiState.value = WeeklySnapshotState.Error(
                                message = errMsg,
                                retainedData = retainedData
                            )
                            _newUiState.update {
                                it.copy(
                                    selectedMetric = metric,
                                    isInitialLoading = false,
                                    isRefreshing = false,
                                    errorMessage = errMsg
                                )
                            }
                        }
                    }
                }
            } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                if (requestId == requestIdGenerator.get()) {
                    val errMsg = "Request timed out while reading Health Connect. Tap refresh to retry."
                    _uiState.value = WeeklySnapshotState.Error(
                        message = errMsg,
                        retainedData = retainedData
                    )
                    _newUiState.update {
                        it.copy(
                            selectedMetric = metric,
                            isInitialLoading = false,
                            isRefreshing = false,
                            errorMessage = errMsg
                        )
                    }
                }
            } catch (e: Exception) {
                if (requestId == requestIdGenerator.get()) {
                    val errMsg = e.message ?: "Failed to load data"
                    _uiState.value = WeeklySnapshotState.Error(
                        message = errMsg,
                        retainedData = retainedData
                    )
                    _newUiState.update {
                        it.copy(
                            selectedMetric = metric,
                            isInitialLoading = false,
                            isRefreshing = false,
                            errorMessage = errMsg
                        )
                    }
                }
            }
        }
    }
}
