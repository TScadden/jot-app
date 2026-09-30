package com.notel.notel.ui.viewmodel

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.data.preferences.NotelPreferences
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import javax.inject.Inject
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.notel.notel.data.model.BiomarkerPoint

@kotlinx.serialization.Serializable
data class CachedMetrics(
    val latestHeartRate: Int = 0,
    val weightPounds: Float = 0f,
    val respiratoryRate: Double = 0.0,
    val bloodOxygen: Double = 0.0,
    val restingHeartRate: Int = 0,
    val todayHRV: Double = 0.0,
    val averageHeartRate: Int = 0,
    val asleepHeartRate: Int = 0,
    val caloriesBurned: Int = 0,
    val intradayHR: List<Pair<Long, Int>> = emptyList()
)

@kotlinx.serialization.Serializable
data class SleepData(
    val minutesAsleep: Int = 0,
    val timeInBed: Int = 0,
    val deepMinutes: Int = 0,
    val lightMinutes: Int = 0,
    val remMinutes: Int = 0,
    val wakeMinutes: Int = 0,
    val efficiency: Int = 0
)

data class FitbitState(
    val isConnected: Boolean = false,
    val isLoading: Boolean = false,
    val heartRateData: List<Pair<Long, Int>> = emptyList(), // epoch Long -> HR int
    val averageHeartRate: Int = 0,
    val asleepHeartRate: Int = 0,
    val latestHeartRate: Int = 0,
    val latestHeartRateTime: String = "",
    val connectedDevices: List<String> = emptyList(), // Can default to ["Health Connect"]
    val historicalHeartRate: List<Pair<String, Int>> = emptyList(), // "YYYY-MM-DD" -> HR
    val historicalSleep: List<Pair<String, Int>> = emptyList(), // "YYYY-MM-DD" -> Minutes Asleep
    val historicalCalories: List<Pair<String, Int>> = emptyList(), // "YYYY-MM-DD" -> Calories
    val sleepData: SleepData? = null,
    val selectedSleepDate: String = "today",
    val selectedHeartRateDate: String = "today",
    val selectedKeyMetricsDate: String = "today",
    val caloriesBurned: Int = 0,
    val isFitbitConnected: Boolean = false,
    val errorMessage: String? = null,
    val historicalSpikes: List<DailyHeartRateSummary> = emptyList(),
    val currentHrv: Double = 0.0,
    val hrvData: List<Pair<String, Double>> = emptyList(),
    val sleepDebtMins: Int = 0,
    val respiratoryRate: Double = 0.0,
    val bloodOxygen: Double = 0.0,
    val restingHeartRate: Int = 0,
    val weightPounds: Float = 0f,
    val todayHRV: Double = 0.0,
    val hasFullPermissions: Boolean = false,
    val isSpikesLoading: Boolean = false,
    val bloodPressureState: com.notel.notel.data.repository.BloodPressureTileState = com.notel.notel.data.repository.BloodPressureTileState.Checking
)


@HiltViewModel
class FitbitViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    val healthConnectManager: HealthConnectManager,
    val healthConnectCoordinator: com.notel.notel.data.healthconnect.HealthConnectCoordinator,
    private val lifecycleTracker: com.notel.notel.util.AppLifecycleTracker,
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: android.content.Context
) : ViewModel() {

    companion object {
        private const val TAG = "FitbitViewModel"
    }

    private val _state = MutableStateFlow(FitbitState(connectedDevices = listOf("Health Connect")))
    val state = _state.asStateFlow()

    private val _isExportingCsv = MutableStateFlow(false)
    val isExportingCsv = _isExportingCsv.asStateFlow()

    private val _csvReadyEvent = MutableSharedFlow<java.io.File>()
    val csvReadyEvent = _csvReadyEvent.asSharedFlow()

    private var lastSyncTime = 0L
    private var cachedDailyStatsMap = mapOf<String, CachedMetrics>()
    private var syncKeyMetricsJob: kotlinx.coroutines.Job? = null

    init {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                // Read daily stats cache on IO thread so startup is instant
                val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
                try {
                    val initialStr = preferences.historicalDailyStats.first()
                    if (initialStr.isNotBlank() && initialStr != "{}") {
                        cachedDailyStatsMap = json.decodeFromString<Map<String, CachedMetrics>>(initialStr)
                    }
                } catch (e: Exception) { /* start with empty map */ }

                launch {
                    preferences.historicalDailyStats.collect { str ->
                        val map = if (str.isNotBlank() && str != "{}") {
                            try {
                                json.decodeFromString<Map<String, CachedMetrics>>(str)
                            } catch (e: Exception) {
                                emptyMap()
                            }
                        } else {
                            emptyMap()
                        }
                        cachedDailyStatsMap = map
                    }
                }
                // One-time Fitbit sunset migration (Fitbit Web API retired Oct 30, 2026):
                // wipe stored OAuth credentials so no dead API calls can fire and the
                // connection state stays honest. Cached history is untouched and keeps serving.
                try {
                    if (!preferences.fitbitSunsetMigrationDone.first()) {
                        preferences.clearFitbitCredentials()
                        preferences.setFitbitSunsetMigrationDone()
                    }
                } catch (e: Exception) { /* credentials stay as-is; no live paths use them anymore */ }
                _state.update { it.copy(isFitbitConnected = false) }
                launch {
                    preferences.historicalHeartRate.collect { str ->
                        if (str.isNotBlank()) {
                            try {
                                val list = json.decodeFromString<List<BiomarkerPoint>>(str)
                                _state.update { it.copy(historicalHeartRate = list.map { p -> p.date to p.value.toInt() }) }
                            } catch(e: Exception) {}
                        }
                    }
                }
                launch {
                    preferences.historicalSleep.collect { str ->
                        if (str.isNotBlank()) {
                            try {
                                val list = json.decodeFromString<List<BiomarkerPoint>>(str)
                                _state.update { it.copy(historicalSleep = list.map { p -> p.date to p.value.toInt() }) }
                            } catch(e: Exception) {}
                        }
                    }
                }
                launch {
                    preferences.historicalCalories.collect { str ->
                        if (str.isNotBlank()) {
                            try {
                                val list = json.decodeFromString<List<BiomarkerPoint>>(str)
                                _state.update { it.copy(historicalCalories = list.map { p -> p.date to p.value.toInt() }) }
                            } catch(e: Exception) {}
                        }
                    }
                }
                launch {
                    preferences.historicalHrSpikes.collect { spikesStr ->
                        if (spikesStr.isNotBlank()) {
                            try {
                                val spikes = json.decodeFromString<List<DailyHeartRateSummary>>(spikesStr)
                                _state.update { it.copy(historicalSpikes = spikes) }
                            } catch(e: Exception) {}
                        }
                    }
                }
            } catch (e: Exception) {
                // Ignore background pref errors
            }
        }
        viewModelScope.launch {
            checkConnectionStatus()
        }
    }

    suspend fun checkConnectionStatus() {
        try {
            val hasBasic = healthConnectManager.hasBasicPermissions()
            val hasFull = healthConnectManager.hasFullPermissions()
            _state.update { it.copy(isConnected = hasBasic, hasFullPermissions = hasFull) }
            refreshBloodPressureState()
            if (hasBasic) {
                sync(force = false)
            }
        } catch (e: Exception) {
            _state.update { it.copy(errorMessage = "Connection check failed") }
        }
    }

    fun refreshBloodPressureState() {
        viewModelScope.launch {
            val repo = com.notel.notel.data.repository.BloodPressureRepository(healthConnectManager, preferences)
            val bpState = repo.getTileState()
            _state.update { it.copy(bloodPressureState = bpState) }
        }
    }

    fun navigateToWorstSpikeDay() {
        viewModelScope.launch {
            try {
                _state.update { it.copy(isLoading = true) }
                // Do a quick 14-day fetch for worst spike navigation
                val freshSpikes = healthConnectManager.readHistoricalHeartRateWithSpikes(14)
                if (freshSpikes.isNotEmpty()) {
                    // Save updated data to DataStore as a side effect
                    preferences.setHistoricalHrSpikes(
                        kotlinx.serialization.json.Json.encodeToString(
                            kotlinx.serialization.serializer<List<DailyHeartRateSummary>>(), freshSpikes
                        )
                    )
                    _state.update { it.copy(historicalSpikes = freshSpikes, isLoading = false) }
                    val currentDate = _state.value.selectedHeartRateDate
                    val worstDay = freshSpikes
                        .filter { it.date != currentDate }
                        .maxByOrNull { it.spikeCount }
                    if (worstDay != null && worstDay.spikeCount > 0) {
                        fetchHeartRateForDate(worstDay.date)
                    }
                } else {
                    _state.update { it.copy(isLoading = false) }
                }
            } catch (e: Exception) {
                // Fallback to cached data
                _state.update { it.copy(isLoading = false) }
                val cached = _state.value.historicalSpikes
                val currentDate = _state.value.selectedHeartRateDate
                val worstDay = cached.filter { it.date != currentDate }.maxByOrNull { it.spikeCount }
                if (worstDay != null && worstDay.spikeCount > 0) {
                    fetchHeartRateForDate(worstDay.date)
                }
            }
        }
    }

    fun sync(force: Boolean = false) {
        if (!force && _state.value.isLoading) return
        
        val currentTime = System.currentTimeMillis()
        if (!force && (currentTime - lastSyncTime < 5 * 60 * 1000)) {
            return
        }

        lastSyncTime = currentTime
        
        viewModelScope.launch {
            try {
                // Health Connect only. The Fitbit Web API was retired (Oct 30, 2026),
                // so the Fitbit branch was removed; cached Fitbit history keeps serving.
                val hasHC = healthConnectManager.hasAllPermissions()

                if (!hasHC) {
                    _state.update { it.copy(isConnected = false, errorMessage = "Connection Required") }
                    return@launch
                }

                _state.update { it.copy(isConnected = true, isLoading = true, errorMessage = null) }

                try {
                    syncFromHealthConnect(fetchHistory = true, forceRefresh = force)
                } catch (e: Exception) {
                    _state.update { it.copy(errorMessage = "Health Connect sync failed") }
                }
            } catch (e: Exception) {
                _state.update { it.copy(errorMessage = "Sync failed: ${e.message}") }
            } finally {
                _state.update { it.copy(isLoading = false) }
            }
        }
    }

    private suspend fun syncFromHealthConnect(fetchHistory: Boolean = false, forceRefresh: Boolean = false) = coroutineScope {
         val targetDate = if (_state.value.selectedKeyMetricsDate == "today") java.time.LocalDate.now().toString() else _state.value.selectedKeyMetricsDate

         val intradayHRDeferred = async { healthConnectCoordinator.getIntradayHeartRate(targetDate, forceRefresh = forceRefresh) }
         val sleepDeferred = async { healthConnectCoordinator.getSleepSession(targetDate) }
         val activeCalDeferred = async { healthConnectCoordinator.getActiveCalories(targetDate) }
         val rhrDeferred = async { healthConnectCoordinator.getRestingHeartRate(targetDate) }
         val weightDeferred = async { healthConnectManager.readLatestWeight(targetDate) }

         val intradayHR = try { intradayHRDeferred.await() } catch(e: Exception) { emptyList() }
         val zoneId = java.time.ZoneId.systemDefault()
         val awake = intradayHR.filter { 
             val h = java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(it.first), zoneId).hour
             h in 7..22
         }
         val asleep = intradayHR.filter { 
             val h = java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(it.first), zoneId).hour
             h >= 23 || h < 7
         }
         val avgHR = if (awake.isNotEmpty()) awake.map{it.second}.average().toInt() else 0
         val asleepHR = if (asleep.isNotEmpty()) asleep.map{it.second}.average().toInt() else 0
         
         val sleepData = try { sleepDeferred.await() } catch(e: Exception) { null }
         val activeCal = try { activeCalDeferred.await() } catch(e: Exception) { 0 }

         var latest = intradayHR.lastOrNull()?.second ?: 0
         val latestTime = intradayHR.lastOrNull()?.first ?: 0L

         val formattedTime = if (latestTime > 0) {
             try {
                 val formatter = java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault())
                 formatter.format(java.util.Date(latestTime))
             } catch(e: Exception) { latestTime.toString() }
         } else ""
         val rhrValue = try { rhrDeferred.await() } catch(e: Exception) { 0 }
         val weightVal = try { weightDeferred.await() ?: 0f } catch(e: Exception) { 0f }

         // Immediate UI update for today's metrics (Home Screen metrics only)
         _state.update { currentState ->
             currentState.copy(
                 heartRateData = if (intradayHR.isNotEmpty()) intradayHR else currentState.heartRateData,
                 averageHeartRate = if (avgHR > 0) avgHR else currentState.averageHeartRate,
                 asleepHeartRate = if (asleepHR > 0) asleepHR else currentState.asleepHeartRate,
                 latestHeartRate = if (latest > 0) latest else currentState.latestHeartRate,
                 latestHeartRateTime = if (formattedTime.isNotBlank()) formattedTime else currentState.latestHeartRateTime,
                 sleepData = sleepData ?: currentState.sleepData,
                 caloriesBurned = if (activeCal > 0) activeCal else currentState.caloriesBurned,
                 sleepDebtMins = calculateDebtAtDate(_state.value.selectedSleepDate, currentState.historicalSleep),
                 restingHeartRate = if (rhrValue > 0) rhrValue else currentState.restingHeartRate,
                 weightPounds = if (weightVal > 0f) weightVal else currentState.weightPounds,
                 errorMessage = if (latest == 0 && avgHR == 0 && currentState.averageHeartRate == 0) "No recent Health Connect data" else null
             )
         }

         // Cache basic metrics only
         try {
             val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
             val cachedStats = CachedMetrics(
                 latestHeartRate = latest,
                 weightPounds = weightVal,
                 restingHeartRate = rhrValue
             )
             preferences.setLastKnownStats(json.encodeToString(cachedStats))
             saveDailyStatToCache(targetDate, cachedStats)
         } catch(e: Exception) {
             android.util.Log.e("FitbitViewModel", "Failed to cache metrics: ${e.message}")
         }

         // Dismiss top loader as soon as active day data is ready!
         _state.update { it.copy(isLoading = false) }

         // PHASE 2: Historical Metrics (Background)
         if (fetchHistory) {
             _state.update { it.copy(isSpikesLoading = true) }
             launch {
                  try {
                      // Fetch LAST 14 DAYS (fast & deduplicated via coordinator!)
                      val histHR14 = try { healthConnectCoordinator.getHeartRateHistory(14) } catch(e: Exception) { emptyList() }
                      val histSpikes14 = try { healthConnectCoordinator.getHrSpikesHistory(14) } catch(e: Exception) { emptyList() }
                      val histSleep14 = try { healthConnectCoordinator.getSleepHistory(14) } catch(e: Exception) { emptyList() }
                      val histCal14 = try { healthConnectCoordinator.getCaloriesHistory(14) } catch(e: Exception) { emptyList() }

                      _state.update { currentState ->
                          currentState.copy(
                              historicalHeartRate = (histHR14 + currentState.historicalHeartRate).distinctBy { it.first }.sortedBy { it.first },
                              historicalSleep = (histSleep14 + currentState.historicalSleep).distinctBy { it.first }.sortedBy { it.first },
                              historicalCalories = (histCal14 + currentState.historicalCalories).distinctBy { it.first }.sortedBy { it.first },
                              historicalSpikes = (histSpikes14 + currentState.historicalSpikes).distinctBy { it.date }.sortedByDescending { it.date },
                              sleepDebtMins = calculateDebtAtDate(_state.value.selectedSleepDate, histSleep14),
                              isSpikesLoading = false
                          )
                      }

                      // Background persistence
                      val json = Json { ignoreUnknownKeys = true }
                      preferences.setHistoricalHeartRate(json.encodeToString(histHR14.map { BiomarkerPoint(it.first, it.second) }))
                      preferences.setHistoricalSleep(json.encodeToString(histSleep14.map { BiomarkerPoint(it.first, it.second) }))
                      preferences.setHistoricalCalories(json.encodeToString(histCal14.map { BiomarkerPoint(it.first, it.second) }))
                      preferences.setHistoricalHrSpikes(json.encodeToString(histSpikes14))
                  } catch(e: Exception) {
                      _state.update { it.copy(isSpikesLoading = false) }
                      android.util.Log.e("FitbitViewModel", "Historical sync failed: ${e.message}")
                  }
             }
         }
    }


    }

    private var fetchHeartRateJob: kotlinx.coroutines.Job? = null

    fun fetchHeartRateForDate(date: String) {
        val todayStr = java.time.LocalDate.now().toString()
        val isTodaySelect = date == "today" || date == todayStr
        val targetDateStr = if (isTodaySelect) todayStr else date
        val stateDateKey = if (isTodaySelect) "today" else date

        // Synchronously update date selection state so UI header & dialog dismiss IMMEDIATELY
        val cached = cachedDailyStatsMap[targetDateStr]
        val hasCachedData = cached != null && (cached.averageHeartRate > 0 || cached.latestHeartRate > 0 || cached.caloriesBurned > 0)
        _state.update { 
            it.copy(
                selectedHeartRateDate = stateDateKey,
                selectedKeyMetricsDate = stateDateKey,
                selectedSleepDate = stateDateKey,
                isLoading = !hasCachedData,
                errorMessage = null,
                heartRateData = cached?.intradayHR ?: emptyList(),
                averageHeartRate = cached?.averageHeartRate ?: 0,
                asleepHeartRate = cached?.asleepHeartRate ?: 0,
                latestHeartRate = cached?.latestHeartRate ?: 0,
                latestHeartRateTime = if (cached != null && cached.intradayHR.isNotEmpty()) {
                    try {
                        val formatter = java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault())
                        formatter.format(java.util.Date(cached.intradayHR.last().first))
                    } catch (e: Exception) { "" }
                } else "",
                caloriesBurned = cached?.caloriesBurned ?: 0,
                currentHrv = cached?.todayHRV ?: 0.0
            ) 
        }

        fetchHeartRateJob?.cancel()
        fetchHeartRateJob = viewModelScope.launch(Dispatchers.IO) {
            val hasHC = healthConnectManager.hasAllPermissions()

            if (!hasHC) return@launch

            var intradayHR: List<Pair<Long, Int>> = emptyList()
            var avgHR = 0
            var asleepHR = 0
            var activeCal = 0
            var currentHrv = 0.0

            if (hasHC) {
                val intradayHRDeferred = async(Dispatchers.IO) { healthConnectCoordinator.getIntradayHeartRate(targetDateStr, forceRefresh = false) }
                val activeCalDeferred = async(Dispatchers.IO) { healthConnectCoordinator.getActiveCalories(targetDateStr, forceRefresh = false) }
                val hrvListDeferred = async(Dispatchers.IO) { healthConnectCoordinator.getHeartRateVariability(1, targetDateStr = targetDateStr, forceRefresh = false) }

                intradayHR = try { intradayHRDeferred.await() } catch(e: Exception) { emptyList() }
                activeCal = try { activeCalDeferred.await() } catch(e: Exception) { 0 }
                val hrvList = try { hrvListDeferred.await() } catch(e: Exception) { emptyList() }

                val zoneId = java.time.ZoneId.systemDefault()
                val awake = intradayHR.filter { 
                    val h = java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(it.first), zoneId).hour
                    h in 7..22
                }
                val asleep = intradayHR.filter { 
                    val h = java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(it.first), zoneId).hour
                    h >= 23 || h < 7
                }
                avgHR = if (awake.isNotEmpty()) awake.map{it.second}.average().toInt() else 0
                asleepHR = if (asleep.isNotEmpty()) asleep.map{it.second}.average().toInt() else 0
                currentHrv = hrvList.find { it.first == targetDateStr }?.second ?: 0.0
            }
            
            var latest = intradayHR.lastOrNull()?.second ?: 0
            val latestTime = intradayHR.lastOrNull()?.first ?: 0L

            val formattedTime = if (latestTime > 0) {
                try {
                    val formatter = java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault())
                    formatter.format(java.util.Date(latestTime))
                } catch(e: Exception) { latestTime.toString() }
            } else ""

            _state.update { currentState ->
                // STRICT DATE GUARD: check match against selected state key or target date
                if (currentState.selectedHeartRateDate == stateDateKey || currentState.selectedHeartRateDate == targetDateStr) {
                    currentState.copy(
                        isLoading = false,
                        heartRateData = intradayHR,
                        averageHeartRate = avgHR,
                        asleepHeartRate = asleepHR,
                        latestHeartRate = latest,
                        latestHeartRateTime = formattedTime,
                        caloriesBurned = activeCal,
                        currentHrv = currentHrv,
                        errorMessage = if (intradayHR.isEmpty() && activeCal == 0 && !hasCachedData) "No data found for this date." else null
                    )
                } else {
                    currentState
                }
            }

            // PERSIST to local storage so future visits to this date are instant!
            if (intradayHR.isNotEmpty() || avgHR > 0 || activeCal > 0) {
                val existing = cachedDailyStatsMap[targetDateStr]
                val newMetrics = CachedMetrics(
                    latestHeartRate = if (latest > 0) latest else existing?.latestHeartRate ?: 0,
                    weightPounds = existing?.weightPounds ?: 0f,
                    respiratoryRate = existing?.respiratoryRate ?: 0.0,
                    bloodOxygen = existing?.bloodOxygen ?: 0.0,
                    restingHeartRate = existing?.restingHeartRate ?: 0,
                    todayHRV = if (currentHrv > 0.0) currentHrv else existing?.todayHRV ?: 0.0,
                    averageHeartRate = if (avgHR > 0) avgHR else existing?.averageHeartRate ?: 0,
                    asleepHeartRate = if (asleepHR > 0) asleepHR else existing?.asleepHeartRate ?: 0,
                    caloriesBurned = if (activeCal > 0) activeCal else existing?.caloriesBurned ?: 0,
                    intradayHR = if (intradayHR.isNotEmpty()) intradayHR else existing?.intradayHR ?: emptyList()
                )
                saveDailyStatToCache(targetDateStr, newMetrics)
            }

            if (targetDateStr == java.time.LocalDate.now().toString() && avgHR > 0) {
                preferences.setTodayAwakeAvgHr(avgHR)
            }
        }
    }


    private suspend fun saveDailyStatToCache(date: String, metrics: CachedMetrics) {
        val targetDateStr = if (date == "today") java.time.LocalDate.now().toString() else date
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        val updatedMap = cachedDailyStatsMap.toMutableMap().apply {
            put(targetDateStr, metrics)
        }
        cachedDailyStatsMap = updatedMap
        preferences.setHistoricalDailyStats(json.encodeToString(updatedMap))
    }

    fun syncKeyMetricsForDate(date: String, showLoader: Boolean = true) {
        // Always work with a resolved date string (never "today") so the date guard compares equal
        val targetDateStr = if (date == "today") java.time.LocalDate.now().toString() else date
        syncKeyMetricsJob?.cancel()
        syncKeyMetricsJob = viewModelScope.launch {
            try {
                if (showLoader) {
                    _state.update { it.copy(isLoading = true, errorMessage = null) }
                }
                
                val hasHC = healthConnectManager.hasAllPermissions()
                if (hasHC) {
                    val isToday = targetDateStr == java.time.LocalDate.now().toString()

                    val intradayHRDeferred = async { healthConnectManager.readHeartRateIntraday(targetDateStr) }
                    val respRateDeferred = async { healthConnectManager.readRespiratoryRate(targetDateStr) }
                    val oxySatDeferred = async { healthConnectManager.readOxygenSaturation(targetDateStr) }
                    val rhrDeferred = async { healthConnectManager.readRestingHeartRate(targetDateStr) }
                    val weightDeferred = async { healthConnectManager.readLatestWeight(targetDateStr) }

                    val intradayHR = try { intradayHRDeferred.await() } catch(e: Exception) { null } ?: emptyList()
                    val respRate = try { respRateDeferred.await() } catch(e: Exception) { null }
                    val oxySat = try { oxySatDeferred.await() } catch(e: Exception) { null }
                    val rhr = try { rhrDeferred.await() } catch(e: Exception) { null }
                    val profileWeight = try { preferences.userWeight.first() } catch(e: Exception) { 0f }
                    val weight = try { weightDeferred.await() } catch(e: Exception) { null }
                        ?: if (profileWeight > 0f) profileWeight else null

                    // HRV is only fetched for past dates — today shows an advisory note and has no end-of-day value yet
                    val hrvForDate: Double = if (!isToday) {
                        try {
                            val hrvList = healthConnectManager.readHeartRateVariability(days = 30)
                            hrvList.find { it.first == targetDateStr }?.second ?: 0.0
                        } catch(e: Exception) { 0.0 }
                    } else 0.0
                    
                    val zoneId = java.time.ZoneId.systemDefault()
                    val awake = intradayHR.filter { 
                        val h = java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(it.first), zoneId).hour
                        h in 7..22
                    }
                    val asleep = intradayHR.filter { 
                        val h = java.time.ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(it.first), zoneId).hour
                        h >= 23 || h < 7
                    }
                    val awakeAvg = if (awake.isNotEmpty()) awake.map{it.second}.average().toInt() else 0
                    val asleepAvg = if (asleep.isNotEmpty()) asleep.map{it.second}.average().toInt() else 0
                    
                    val latestHR = intradayHR.lastOrNull()?.second ?: 0
                    val latestTime = intradayHR.lastOrNull()?.first ?: 0L
                    val formattedTime = if (latestTime > 0) {
                        try {
                            val formatter = java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault())
                            formatter.format(java.util.Date(latestTime))
                        } catch(e: Exception) { "" }
                    } else ""
                    
                    _state.update { currentState ->
                        // STRICT DATE GUARD: compare resolved date strings only
                        if (currentState.selectedKeyMetricsDate == targetDateStr) {
                            val resolvedHrv = if (isToday) {
                                currentState.currentHrv
                            } else {
                                if (hrvForDate > 0.0) {
                                    hrvForDate
                                } else {
                                    val cachedVal = cachedDailyStatsMap[targetDateStr]?.todayHRV ?: 0.0
                                    if (cachedVal > 0.0) {
                                        cachedVal
                                    } else {
                                        currentState.hrvData.find { it.first == targetDateStr }?.second ?: 0.0
                                    }
                                }
                            }
                            currentState.copy(
                                heartRateData = intradayHR,
                                averageHeartRate = awakeAvg,
                                asleepHeartRate = asleepAvg,
                                latestHeartRate = latestHR,
                                latestHeartRateTime = formattedTime,
                                respiratoryRate = respRate ?: currentState.respiratoryRate,
                                bloodOxygen = oxySat ?: currentState.bloodOxygen,
                                restingHeartRate = rhr ?: currentState.restingHeartRate,
                                weightPounds = weight ?: currentState.weightPounds,
                                todayHRV = if (isToday) currentState.todayHRV else resolvedHrv,
                                currentHrv = resolvedHrv
                            )
                        } else {
                            currentState
                        }
                    }

                    // Save daily stats to cache ONLY if the user is still on this date
                    if (_state.value.selectedKeyMetricsDate == targetDateStr) {
                        val existing = cachedDailyStatsMap[targetDateStr]
                        val cachedStats = CachedMetrics(
                            latestHeartRate = latestHR,
                            weightPounds = weight ?: existing?.weightPounds ?: 0f,
                            respiratoryRate = respRate ?: existing?.respiratoryRate ?: 0.0,
                            bloodOxygen = oxySat ?: existing?.bloodOxygen ?: 0.0,
                            restingHeartRate = rhr ?: existing?.restingHeartRate ?: 0,
                            todayHRV = if (!isToday && hrvForDate > 0.0) hrvForDate else existing?.todayHRV ?: 0.0
                        )
                        saveDailyStatToCache(targetDateStr, cachedStats)
                    }
                }
            } catch (e: Exception) {
                if (showLoader) {
                    _state.update {
                        it.copy(
                            errorMessage = com.notel.notel.util.FriendlyErrors.forBackendError(
                                TAG, e, com.notel.notel.util.FriendlyErrors.Kind.LOAD
                            ).banner
                        )
                    }
                }
            } finally {
                // Only dismiss loader if the active date matches the queried date
                if (showLoader && _state.value.selectedKeyMetricsDate == targetDateStr) {
                    _state.update { it.copy(isLoading = false) }
                }
            }
        }
    }

    fun fetchMetricsForDate(date: String) {
        // Always resolve to a concrete date string — never store "today" in state
        val targetDateStr = if (date == "today") java.time.LocalDate.now().toString() else date

        viewModelScope.launch {
            val isToday = targetDateStr == java.time.LocalDate.now().toString()
            val profileWeight = try { preferences.userWeight.first() } catch(e: Exception) { 0f }
            // If the cache map hasn't been populated yet by the background collector,
            // read it synchronously right now before making any loading decisions.
            // This prevents all tiles from spinning on first open when data is in local storage.
            if (cachedDailyStatsMap.isEmpty()) {
                try {
                    val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
                    val str = preferences.historicalDailyStats.first()
                    if (str.isNotBlank() && str != "{}") {
                        cachedDailyStatsMap = json.decodeFromString<Map<String, CachedMetrics>>(str)
                    }
                } catch (e: Exception) { /* proceed with empty cache */ }
            }

            val cached = cachedDailyStatsMap[targetDateStr]
            val hasData = cached != null && (
                cached.latestHeartRate > 0 ||
                cached.weightPounds > 0f ||
                cached.respiratoryRate > 0.0 ||
                cached.bloodOxygen > 0.0 ||
                cached.restingHeartRate > 0 ||
                cached.todayHRV > 0.0
            )

            _state.update { currentState ->
                val resolvedHrv = if (isToday) {
                    if ((cached?.todayHRV ?: 0.0) > 0.0) {
                        cached!!.todayHRV
                    } else {
                        currentState.hrvData.lastOrNull()?.second ?: currentState.currentHrv
                    }
                } else {
                    if ((cached?.todayHRV ?: 0.0) > 0.0) {
                        cached!!.todayHRV
                    } else {
                        currentState.hrvData.find { it.first == targetDateStr }?.second ?: 0.0
                    }
                }

                currentState.copy(
                    selectedKeyMetricsDate = targetDateStr,
                    selectedHeartRateDate = targetDateStr,
                    selectedSleepDate = targetDateStr,
                    heartRateData = if (!hasData) emptyList() else currentState.heartRateData,
                    latestHeartRate = cached?.latestHeartRate ?: 0,
                    weightPounds = if ((cached?.weightPounds ?: 0f) > 0f) cached!!.weightPounds else profileWeight,
                    respiratoryRate = cached?.respiratoryRate ?: 0.0,
                    bloodOxygen = cached?.bloodOxygen ?: 0.0,
                    restingHeartRate = cached?.restingHeartRate ?: 0,
                    todayHRV = cached?.todayHRV ?: 0.0,
                    currentHrv = resolvedHrv,
                    isLoading = !hasData
                )
            }

            // Sync fresh data in the background; only show loader if nothing was cached
            syncKeyMetricsForDate(targetDateStr, showLoader = !hasData)
        }
    }

    fun fetchSleepForDate(date: String) {
        viewModelScope.launch {
            val hasHC = healthConnectManager.hasAllPermissions()

            if (!hasHC) return@launch

            _state.update { it.copy(isLoading = true, errorMessage = null, selectedSleepDate = date) }
            
            var sleepData: SleepData? = null
            // Only fetch from Health Connect
            sleepData = healthConnectManager.readSleepSession(date)

            // Calculate debt for the selected date
            val targetHours = 8.0
            var runningDebt = 0.0
            val rolling = state.value.historicalSleep
                .filter { it.first <= date }
                .sortedBy { it.first }
                .takeLast(10)
            
            rolling.forEach { (_, mins) ->
                val actualHours = mins / 60.0
                if (actualHours < targetHours) {
                    runningDebt += (targetHours - actualHours)
                } else {
                    val surplus = actualHours - targetHours
                    runningDebt -= Math.min(surplus, 1.5)
                }
                runningDebt = Math.max(0.0, runningDebt)
            }

            _state.update { 
                it.copy(
                    isLoading = false,
                    sleepData = sleepData,
                    sleepDebtMins = (-runningDebt * 60).toInt(),
                    errorMessage = if (sleepData == null) "No sleep data found for this date." else null
                )
            }
        }
    }


    fun disconnectHealthConnect() {
        viewModelScope.launch {
            _state.update { it.copy(isConnected = false) }
            // Note: System permissions can't be revoked via API easily, 
            // but we stop showing it as connected in Jot.
        }
    }

    fun disconnectFitbit() {
        viewModelScope.launch {
            preferences.setFitbitToken("")
            preferences.setFitbitRefreshToken("")
            preferences.clearFitbitOauthPending()
            _state.update { it.copy(isFitbitConnected = false) }
        }
    }

    fun onPermissionsGranted() {
        viewModelScope.launch {
            _state.update { it.copy(isConnected = true) }
            sync(force = true)
        }
    }


    private fun calculateDebtAtDate(date: String, history: List<Pair<String, Int>>): Int {
        val targetHours = 8.0
        var runningDebt = 0.0
        val rolling = history
            .filter { it.first <= date }
            .sortedBy { it.first }
            .takeLast(10)
        
        rolling.forEach { (_, mins) ->
            val actualHours = mins / 60.0
            if (actualHours < targetHours) {
                runningDebt += (targetHours - actualHours)
            } else {
                val surplus = actualHours - targetHours
                runningDebt -= Math.min(surplus, 1.5)
            }
            runningDebt = Math.max(0.0, runningDebt)
        }
        return (-runningDebt * 60).toInt()
    }

    suspend fun exportMetricsCsv(days: Int, includeSpikes: Boolean): String = withContext(Dispatchers.IO) {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        val hasHC = healthConnectManager.hasAllPermissions()

        val today = java.time.LocalDate.now()
        val resolvedDays = if (days == -1) 3650 else days
        
        val avgHrMap = mutableMapOf<String, Int>()
        val sleepDurationMap = mutableMapOf<String, Int>()
        val deepSleepMap = mutableMapOf<String, Int>()
        val spikesMap = mutableMapOf<String, Int>()
        
        // ── Get Health Connect Data ──
        if (hasHC) {
            try {
                // Heart Rate Average
                val hcHr = healthConnectManager.readHistoricalHeartRate(resolvedDays)
                hcHr.forEach { (date, avg) -> avgHrMap[date] = avg }
                
                // Heart Rate Spikes
                if (includeSpikes) {
                    val hcSpikes = healthConnectManager.readHistoricalHeartRateWithSpikes(resolvedDays)
                    hcSpikes.forEach { summary -> spikesMap[summary.date] = summary.spikeCount }
                }
                
                // Sleep details
                val hcSleep = healthConnectManager.readHistoricalSleepWithDeep(resolvedDays)
                hcSleep.forEach { summary ->
            }
        }
        
        // ── Local cache fallback ──
        try {
            val cachedHR = preferences.historicalHeartRate.first()
            if (cachedHR.isNotBlank()) {
                val list = json.decodeFromString<List<BiomarkerPoint>>(cachedHR)
                list.forEach { p -> 
                    if (!avgHrMap.containsKey(p.date) || avgHrMap[p.date] == 0) {
                        avgHrMap[p.date] = p.value.toInt()
                    }
                }
            }
        } catch (e: Exception) {}

        try {
            val cachedSleep = preferences.historicalSleep.first()
            if (cachedSleep.isNotBlank()) {
                val list = json.decodeFromString<List<BiomarkerPoint>>(cachedSleep)
                list.forEach { p -> 
                    if (!sleepDurationMap.containsKey(p.date) || sleepDurationMap[p.date] == 0) {
                        sleepDurationMap[p.date] = p.value.toInt()
                    }
                }
            }
        } catch (e: Exception) {}

        try {
            val cachedSpikes = preferences.historicalHrSpikes.first()
            if (cachedSpikes.isNotBlank()) {
                val list = json.decodeFromString<List<com.notel.notel.data.healthconnect.DailyHeartRateSummary>>(cachedSpikes)
                list.forEach { summary -> 
                    if (!spikesMap.containsKey(summary.date) || spikesMap[summary.date] == 0) {
                        spikesMap[summary.date] = summary.spikeCount
                    }
                }
            }
        } catch (e: Exception) {}
        
        val datesList = if (days == -1) {
            val earliestDateStr = (avgHrMap.keys + sleepDurationMap.keys + deepSleepMap.keys + spikesMap.keys)
                .filter { it.isNotBlank() }
                .minOrNull()
            if (earliestDateStr != null) {
                try {
                    val earliestDate = java.time.LocalDate.parse(earliestDateStr)
                    val daysBetween = java.time.temporal.ChronoUnit.DAYS.between(earliestDate, today).toInt()
                    (0..daysBetween).map { today.minusDays(it.toLong()).toString() }
                } catch(e: Exception) {
                    (0 until 365).map { today.minusDays(it.toLong()).toString() }
                }
            } else {
                emptyList()
            }
        } else {
            (0 until days).map { today.minusDays(it.toLong()).toString() }
        }

        // ── Generate CSV ──
        val csv = StringBuilder()
        csv.append("Date,Average HR (BPM),Sleep Duration,Deep Sleep,Spikes (count)\n")

        fun centerPad(text: String, width: Int): String {
            if (text.length >= width) return text
            val totalPadding = width - text.length
            val leftPadding = totalPadding / 2
            val rightPadding = totalPadding - leftPadding
            return " ".repeat(leftPadding) + text + " ".repeat(rightPadding)
        }

        fun formatMinsToHoursMins(mins: Int): String {
            val h = mins / 60
            val m = mins % 60
            return "${h}h ${m}m"
        }

        datesList.sortedDescending().forEach { date ->
            val avgHrVal = avgHrMap[date]?.let { if (it == 0) "No data" else it.toString() } ?: "No data"
            val sleepMinsVal = sleepDurationMap[date]?.let { if (it == 0) "No data" else formatMinsToHoursMins(it) } ?: "No data"
            val deepMinsVal = deepSleepMap[date]?.let { if (it == 0) "No data" else formatMinsToHoursMins(it) } ?: "No data"
            val spikesVal = spikesMap[date]?.toString() ?: "No data"

            val dateC = centerPad(date, 10)
            val avgHrC = centerPad(avgHrVal, 18)
            val sleepMinsC = centerPad(sleepMinsVal, 14)
            val deepMinsC = centerPad(deepMinsVal, 10)
            val spikesC = centerPad(spikesVal, 14)

            csv.append("$dateC,$avgHrC,$sleepMinsC,$deepMinsC,$spikesC\n")
        }
        
        csv.toString()
    }

    @OptIn(kotlinx.coroutines.DelicateCoroutinesApi::class)
    fun exportMetricsCsvAsync(days: Int, includeSpikes: Boolean) {
        if (_isExportingCsv.value) return
        _isExportingCsv.value = true
        kotlinx.coroutines.GlobalScope.launch {
            try {
                val csvContent = exportMetricsCsv(days, includeSpikes)
                val fileName = if (days == -1) "jot_metrics_alltime.csv" else "jot_metrics_${days}d.csv"
                val cacheFile = java.io.File(context.cacheDir, fileName)
                cacheFile.writeText(csvContent)

                // Save to Downloads
                val resolver = context.contentResolver
                val contentValues = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "text/csv")
                    put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, android.os.Environment.DIRECTORY_DOWNLOADS)
                }
                val uri = resolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                uri?.let {
                    resolver.openOutputStream(it)?.use { os ->
                        os.write(csvContent.toByteArray())
                    }
                }

                _csvReadyEvent.emit(cacheFile)

                // Send notification if app is backgrounded
                if (!lifecycleTracker.isAppInForeground.value) {
                    com.notel.notel.util.NotificationHelper(context).showCsvReady(cacheFile)
                }
            } catch (e: Exception) {
                android.util.Log.e("FitbitViewModel", "exportMetricsCsvAsync failed", e)
            } finally {
                _isExportingCsv.value = false
            }
        }
    }
}
