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
    val isSpikesLoading: Boolean = false
)


@HiltViewModel
class FitbitViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    val healthConnectManager: HealthConnectManager,
    private val lifecycleTracker: com.notel.notel.util.AppLifecycleTracker,
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: android.content.Context
) : ViewModel() {

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
                launch {
                    preferences.fitbitToken.collect { token ->
                        _state.update { it.copy(isFitbitConnected = token.isNotBlank()) }
                    }
                }
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
            if (hasBasic) {
                sync(force = false)
            }
        } catch (e: Exception) {
            _state.update { it.copy(errorMessage = "Connection check failed") }
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
                val hasHC = healthConnectManager.hasAllPermissions()
                val token = preferences.fitbitToken.first()
                
                if (!hasHC && token.isBlank()) {
                    _state.update { it.copy(isConnected = false, errorMessage = "Connection Required") }
                    return@launch
                }

                _state.update { it.copy(isConnected = true, isLoading = true, errorMessage = null) }
                
                if (hasHC) {
                    try {
                        syncFromHealthConnect(fetchHistory = true)
                    } catch (e: Exception) {
                        _state.update { it.copy(errorMessage = "Health Connect sync failed") }
                    }
                }
                
                if (token.isNotBlank()) {
                    launch {
                        try {
                            fetchFromFitbitApi(token)
                        } catch (e: Exception) {}
                    }
                }
            } catch (e: Exception) {
                _state.update { it.copy(errorMessage = "Sync failed: ${e.message}") }
            } finally {
                _state.update { it.copy(isLoading = false) }
            }
        }
    }

    private suspend fun syncFromHealthConnect(fetchHistory: Boolean = false) = coroutineScope {
         val targetDate = if (_state.value.selectedKeyMetricsDate == "today") java.time.LocalDate.now().toString() else _state.value.selectedKeyMetricsDate

         val intradayHRDeferred = async { healthConnectManager.readHeartRateIntraday(targetDate) }
         val avgHRDeferred = async { healthConnectManager.readHeartRateAverage(targetDate) }
         val sleepDeferred = async { healthConnectManager.readSleepSession(targetDate) }
         val activeCalDeferred = async { healthConnectManager.readActiveCalories(targetDate) }
         val rhrDeferred = async { healthConnectManager.readRestingHeartRate(targetDate) }
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
         val rhrValue = try { rhrDeferred.await() ?: 0 } catch(e: Exception) { 0 }
         val weightVal = try { weightDeferred.await() ?: 0f } catch(e: Exception) { 0f }

         // Immediate UI update for today's metrics (Home Screen metrics only)
         _state.update { 
             it.copy(
                 heartRateData = intradayHR,
                 averageHeartRate = avgHR,
                 asleepHeartRate = asleepHR,
                 latestHeartRate = latest,
                 latestHeartRateTime = formattedTime,
                 sleepData = sleepData,
                 caloriesBurned = activeCal,
                 sleepDebtMins = calculateDebtAtDate(_state.value.selectedSleepDate, _state.value.historicalSleep),
                 restingHeartRate = rhrValue,
                 weightPounds = weightVal,
                 errorMessage = if (latest == 0 && avgHR == 0) "No recent HC data found" else null
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
                      // 1. Fetch LAST 7 DAYS first (super fast!)
                      val histHR7 = try { healthConnectManager.readHistoricalHeartRate(7) } catch(e: Exception) { emptyList() }
                      val histSpikes7 = try { healthConnectManager.readHistoricalHeartRateWithSpikes(7) } catch(e: Exception) { emptyList() }
                      val histSleep7 = try { healthConnectManager.readHistoricalSleep(7) } catch(e: Exception) { emptyList() }
                      val histCal7 = try { healthConnectManager.readHistoricalCalories(7) } catch(e: Exception) { emptyList() }

                      _state.update { currentState ->
                          currentState.copy(
                              historicalHeartRate = (histHR7 + currentState.historicalHeartRate).distinctBy { it.first }.sortedBy { it.first },
                              historicalSleep = (histSleep7 + currentState.historicalSleep).distinctBy { it.first }.sortedBy { it.first },
                              historicalCalories = (histCal7 + currentState.historicalCalories).distinctBy { it.first }.sortedBy { it.first },
                              historicalSpikes = (histSpikes7 + currentState.historicalSpikes).distinctBy { it.date }.sortedByDescending { it.date },
                              sleepDebtMins = calculateDebtAtDate(_state.value.selectedSleepDate, histSleep7)
                          )
                      }

                      // 2. Fetch the rest (30/90 days) in a background coroutine
                      launch {
                          try {
                              val histHR = try { healthConnectManager.readHistoricalHeartRate(180) } catch(e: Exception) { _state.value.historicalHeartRate }
                              val histSpikes = try { healthConnectManager.readHistoricalHeartRateWithSpikes(14) } catch(e: Exception) { _state.value.historicalSpikes }
                              val histSleep = try { healthConnectManager.readHistoricalSleep(180) } catch(e: Exception) { _state.value.historicalSleep }
                              val histCal = try { healthConnectManager.readHistoricalCalories(180) } catch(e: Exception) { _state.value.historicalCalories }

                              _state.update { currentState ->
                                  currentState.copy(
                                      historicalHeartRate = (histHR + currentState.historicalHeartRate).distinctBy { it.first }.sortedBy { it.first },
                                      historicalSleep = (histSleep + currentState.historicalSleep).distinctBy { it.first }.sortedBy { it.first },
                                      historicalCalories = (histCal + currentState.historicalCalories).distinctBy { it.first }.sortedBy { it.first },
                                      historicalSpikes = (histSpikes + currentState.historicalSpikes).distinctBy { it.date }.sortedByDescending { it.date },
                                      sleepDebtMins = calculateDebtAtDate(_state.value.selectedSleepDate, histSleep)
                                  )
                              }

                              // Background persistence
                              val json = Json { ignoreUnknownKeys = true }
                              preferences.setHistoricalHeartRate(json.encodeToString(histHR.map { BiomarkerPoint(it.first, it.second) }))
                              preferences.setHistoricalSleep(json.encodeToString(histSleep.map { BiomarkerPoint(it.first, it.second) }))
                              preferences.setHistoricalCalories(json.encodeToString(histCal.map { BiomarkerPoint(it.first, it.second) }))
                              preferences.setHistoricalHrSpikes(json.encodeToString(histSpikes))

                                  _state.update { it.copy(isSpikesLoading = false) }
                          } catch(e: Exception) {
                              _state.update { it.copy(isSpikesLoading = false) }
                          }
                      }
                  } catch(e: Exception) {
                      _state.update { it.copy(isSpikesLoading = false) }
                      android.util.Log.e("FitbitViewModel", "Historical sync failed: ${e.message}")
                  }
              }
          }
    }

    private suspend fun fetchFromFitbitApi(token: String) {
        withContext(Dispatchers.IO) {
            val client = okhttp3.OkHttpClient()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            
            try {
                // 1. Heart Rate History (6 Months)
                val hrHistRequest = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1/user/-/activities/heart/date/today/6m.json")
                    .header("Authorization", "Bearer $token")
                    .build()
                
                val hrList = client.newCall(hrHistRequest).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        val root = json.parseToJsonElement(body).jsonObject
                        root["activities-heart"]?.jsonArray?.mapNotNull { el ->
                            val obj = el.jsonObject
                            val date = obj["dateTime"]?.jsonPrimitive?.content ?: ""
                            val valObj = obj["value"]?.jsonObject
                            val rhr = valObj?.get("restingHeartRate")?.jsonPrimitive?.intOrNull ?: 0
                            if (date.isNotBlank() && rhr > 0) date to rhr else null
                        } ?: emptyList()
                    } else emptyList()
                }
                
                if (hrList.isNotEmpty()) {
                    val currentStr = preferences.historicalHeartRate.first()
                    val current = try {
                        if (currentStr.isNotBlank()) json.decodeFromString<List<BiomarkerPoint>>(currentStr).map { it.date to it.value } else emptyList()
                    } catch (e: Exception) { emptyList() }
                    
                    val combined = (current + hrList).distinctBy { it.first }.sortedByDescending { it.first }
                    preferences.setHistoricalHeartRate(json.encodeToString(combined.map { BiomarkerPoint(it.first, it.second) }))
                    _state.update { it.copy(historicalHeartRate = combined) }
                }

                // 2. Calories History (6 Months)
                val calHistRequest = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1/user/-/activities/calories/date/today/6m.json")
                    .header("Authorization", "Bearer $token")
                    .build()
                
                val calList = client.newCall(calHistRequest).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        val root = json.parseToJsonElement(body).jsonObject
                        root["activities-calories"]?.jsonArray?.mapNotNull { el ->
                            val obj = el.jsonObject
                            val date = obj["dateTime"]?.jsonPrimitive?.content ?: ""
                            val cal = obj["value"]?.jsonPrimitive?.intOrNull ?: 0
                            if (date.isNotBlank() && cal > 0) date to cal else null
                        } ?: emptyList()
                    } else emptyList()
                }
                
                if (calList.isNotEmpty()) {
                    val currentStr = preferences.historicalCalories.first()
                    val current = try {
                        if (currentStr.isNotBlank()) json.decodeFromString<List<BiomarkerPoint>>(currentStr).map { it.date to it.value } else emptyList()
                    } catch (e: Exception) { emptyList() }

                    val combined = (current + calList).distinctBy { it.first }.sortedByDescending { it.first }
                    preferences.setHistoricalCalories(json.encodeToString(combined.map { BiomarkerPoint(it.first, it.second) }))
                    _state.update { it.copy(historicalCalories = combined) }
                }

                // 3. Sleep History (6 Months via Sleep List)
                val todayStr = java.time.LocalDate.now().toString()
                val sleepHistRequest = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1.2/user/-/sleep/list.json?beforeDate=$todayStr&sort=desc&offset=0&limit=180")
                    .header("Authorization", "Bearer $token")
                    .build()
                
                val sleepList = client.newCall(sleepHistRequest).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        val root = json.parseToJsonElement(body).jsonObject
                        val sleepArray = root["sleep"]?.jsonArray ?: JsonArray(emptyList())
                        sleepArray.mapNotNull { el ->
                            val obj = el.jsonObject
                            val date = obj["dateOfSleep"]?.jsonPrimitive?.content ?: ""
                            val minAsleep = obj["minutesAsleep"]?.jsonPrimitive?.intOrNull ?: 0
                            if (date.isNotBlank() && minAsleep > 0) date to minAsleep else null
                        }
                    } else emptyList()
                }
                
                if (sleepList.isNotEmpty()) {
                    val currentStr = preferences.historicalSleep.first()
                    val current = try {
                        if (currentStr.isNotBlank()) json.decodeFromString<List<BiomarkerPoint>>(currentStr).map { it.date to it.value } else emptyList()
                    } catch (e: Exception) { emptyList() }

                    val combined = (current + sleepList).distinctBy { it.first }.sortedByDescending { it.first }
                    preferences.setHistoricalSleep(json.encodeToString(combined.map { BiomarkerPoint(it.first, it.second) }))
                    _state.update { it.copy(historicalSleep = combined) }
                }
            } catch (e: Exception) {
                android.util.Log.e("FitbitViewModel", "Historical sync failed: ${e.message}")
            }
        }
    }

    private fun <T> List<T>.firstBy(predicate: (T) -> Boolean): T? = firstOrNull(predicate)

    private suspend fun fetchWeightFromCloud(token: String, date: String): Double? {
        return withContext(Dispatchers.IO) {
            val client = okhttp3.OkHttpClient()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            try {
                android.util.Log.d("FitbitViewModel", "Fetching Weight from Fitbit Web API for last 30 days ending $date...")
                val request = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1/user/-/body/log/weight/date/$date/30d.json")
                    .header("Authorization", "Bearer $token")
                    .header("Accept-Language", "en_US")
                    .build()
                client.newCall(request).execute().use { response ->
                    android.util.Log.d("FitbitViewModel", "Fitbit Weight response code: ${response.code}")
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        android.util.Log.d("FitbitViewModel", "Fitbit Weight response body: $body")
                        val root = json.parseToJsonElement(body).jsonObject
                        val weightArr = root["weight"]?.jsonArray
                        val valObj = weightArr?.lastOrNull()?.jsonObject
                        val weightVal = valObj?.get("weight")?.jsonPrimitive?.doubleOrNull
                        android.util.Log.d("FitbitViewModel", "Fitbit Weight parsed value: $weightVal")
                        weightVal
                    } else {
                        val errBody = response.body?.string() ?: ""
                        android.util.Log.e("FitbitViewModel", "Fitbit Weight request failed with code ${response.code}: $errBody")
                        null
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("FitbitViewModel", "Exception in fetchWeightFromCloud: ${e.message}", e)
                null
            }
        }
    }

    private suspend fun fetchSpO2FromCloud(token: String, date: String): Double? {
        return withContext(Dispatchers.IO) {
            val client = okhttp3.OkHttpClient()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            try {
                android.util.Log.d("FitbitViewModel", "Fetching SpO2 from Fitbit Web API for $date...")
                val request = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1/user/-/spo2/date/$date.json")
                    .header("Authorization", "Bearer $token")
                    .build()
                client.newCall(request).execute().use { response ->
                    android.util.Log.d("FitbitViewModel", "Fitbit SpO2 response code: ${response.code}")
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        android.util.Log.d("FitbitViewModel", "Fitbit SpO2 response body: $body")
                        val root = json.parseToJsonElement(body).jsonObject
                        val valObj = if (root.containsKey("spo2")) {
                            root["spo2"]?.jsonArray?.firstOrNull()?.jsonObject?.get("value")?.jsonObject
                        } else {
                            root["value"]?.jsonObject
                        }
                        val valDouble = valObj?.get("avg")?.jsonPrimitive?.doubleOrNull
                        android.util.Log.d("FitbitViewModel", "Fitbit SpO2 parsed value: $valDouble")
                        valDouble
                    } else {
                        val errBody = response.body?.string() ?: ""
                        android.util.Log.e("FitbitViewModel", "Fitbit SpO2 request failed with code ${response.code}: $errBody")
                        null
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("FitbitViewModel", "Exception in fetchSpO2FromCloud: ${e.message}", e)
                null
            }
        }
    }

    private suspend fun fetchRespiratoryRateFromCloud(token: String, date: String): Double? {
        return withContext(Dispatchers.IO) {
            val client = okhttp3.OkHttpClient()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            try {
                android.util.Log.d("FitbitViewModel", "Fetching Respiratory Rate from Fitbit Web API for $date...")
                val request = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1/user/-/br/date/$date.json")
                    .header("Authorization", "Bearer $token")
                    .build()
                client.newCall(request).execute().use { response ->
                    android.util.Log.d("FitbitViewModel", "Fitbit Respiratory Rate response code: ${response.code}")
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        android.util.Log.d("FitbitViewModel", "Fitbit Respiratory Rate response body: $body")
                        val root = json.parseToJsonElement(body).jsonObject
                        val valObj = if (root.containsKey("br")) {
                            root["br"]?.jsonArray?.firstOrNull()?.jsonObject?.get("value")?.jsonObject
                        } else {
                            root["value"]?.jsonObject
                        }
                        val valDouble = valObj?.get("breathingRate")?.jsonPrimitive?.doubleOrNull
                        android.util.Log.d("FitbitViewModel", "Fitbit Respiratory Rate parsed value: $valDouble")
                        valDouble
                    } else {
                        val errBody = response.body?.string() ?: ""
                        android.util.Log.e("FitbitViewModel", "Fitbit Respiratory Rate request failed with code ${response.code}: $errBody")
                        null
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("FitbitViewModel", "Exception in fetchRespiratoryRateFromCloud: ${e.message}", e)
                null
            }
        }
    }

    private suspend fun fetchHrvFromCloud(token: String, date: String): Double? {
        return withContext(Dispatchers.IO) {
            val client = okhttp3.OkHttpClient()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            try {
                android.util.Log.d("FitbitViewModel", "Fetching HRV from Fitbit Web API for $date...")
                val request = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1/user/-/hrv/date/$date.json")
                    .header("Authorization", "Bearer $token")
                    .build()
                client.newCall(request).execute().use { response ->
                    android.util.Log.d("FitbitViewModel", "Fitbit HRV response code: ${response.code}")
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        android.util.Log.d("FitbitViewModel", "Fitbit HRV response body: $body")
                        val root = json.parseToJsonElement(body).jsonObject
                        val valObj = if (root.containsKey("hrv")) {
                            root["hrv"]?.jsonArray?.firstOrNull()?.jsonObject?.get("value")?.jsonObject
                        } else {
                            root["value"]?.jsonObject
                        }
                        val valDouble = valObj?.get("dailyRmssd")?.jsonPrimitive?.doubleOrNull
                        android.util.Log.d("FitbitViewModel", "Fitbit HRV parsed value: $valDouble")
                        valDouble
                    } else {
                        val errBody = response.body?.string() ?: ""
                        android.util.Log.e("FitbitViewModel", "Fitbit HRV request failed with code ${response.code}: $errBody")
                        null
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("FitbitViewModel", "Exception in fetchHrvFromCloud: ${e.message}", e)
                null
            }
        }
    }

    private var fetchHeartRateJob: kotlinx.coroutines.Job? = null

    fun fetchHeartRateForDate(date: String) {
        val targetDateStr = if (date == "today") java.time.LocalDate.now().toString() else date

        // Synchronously update date selection state so UI header & dialog dismiss IMMEDIATELY
        val cached = cachedDailyStatsMap[targetDateStr]
        val hasCachedData = cached != null && (cached.averageHeartRate > 0 || cached.latestHeartRate > 0 || cached.caloriesBurned > 0)
        _state.update { 
            it.copy(
                selectedHeartRateDate = targetDateStr,
                selectedKeyMetricsDate = targetDateStr,
                selectedSleepDate = targetDateStr,
                isLoading = !hasCachedData,
                errorMessage = null,
                heartRateData = cached?.intradayHR ?: emptyList(),
                averageHeartRate = cached?.averageHeartRate ?: 0,
                asleepHeartRate = cached?.asleepHeartRate ?: 0,
                latestHeartRate = cached?.latestHeartRate ?: 0,
                caloriesBurned = cached?.caloriesBurned ?: 0,
                currentHrv = cached?.todayHRV ?: 0.0
            ) 
        }

        fetchHeartRateJob?.cancel()
        fetchHeartRateJob = viewModelScope.launch(Dispatchers.IO) {
            val hasHC = healthConnectManager.hasAllPermissions()
            val token = preferences.fitbitToken.first()
            
            if (!hasHC && token.isBlank()) return@launch

            var intradayHR: List<Pair<Long, Int>> = emptyList()
            var avgHR = 0
            var asleepHR = 0
            var activeCal = 0
            var currentHrv = 0.0

            if (hasHC) {
                val intradayHRDeferred = async(Dispatchers.IO) { healthConnectManager.readHeartRateIntraday(targetDateStr) }
                val activeCalDeferred = async(Dispatchers.IO) { healthConnectManager.readActiveCalories(targetDateStr) }
                val hrvListDeferred = async(Dispatchers.IO) { healthConnectManager.readHeartRateVariability(targetDateStr = targetDateStr) }

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
                // STRICT DATE GUARD: only apply result if user is still on this date
                if (currentState.selectedHeartRateDate == targetDateStr) {
                    currentState.copy(
                        isLoading = false,
                        heartRateData = if (intradayHR.isNotEmpty()) intradayHR else currentState.heartRateData,
                        averageHeartRate = if (avgHR > 0) avgHR else currentState.averageHeartRate,
                        asleepHeartRate = if (asleepHR > 0) asleepHR else currentState.asleepHeartRate,
                        latestHeartRate = if (latest > 0) latest else currentState.latestHeartRate,
                        latestHeartRateTime = if (formattedTime.isNotBlank()) formattedTime else currentState.latestHeartRateTime,
                        caloriesBurned = if (activeCal > 0) activeCal else currentState.caloriesBurned,
                        currentHrv = if (currentHrv > 0.0) currentHrv else currentState.currentHrv,
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

    private suspend fun fetchHeartRateFromCloud(token: String, date: String): Triple<List<Pair<String, Int>>, Int, Int>? {
        return withContext(Dispatchers.IO) {
            val client = okhttp3.OkHttpClient()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            try {
                // Fetch HR Intraday (1min resolution)
                val hrRequest = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1/user/-/activities/heart/date/$date/1d/1min.json")
                    .header("Authorization", "Bearer $token")
                    .build()
                
                var hrList = emptyList<Pair<String, Int>>()
                var restingHr = 0
                client.newCall(hrRequest).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        val root = json.parseToJsonElement(body).jsonObject
                        hrList = root["activities-heart-intraday"]?.jsonObject?.get("dataset")?.jsonArray?.mapNotNull { el ->
                            val obj = el.jsonObject
                            val time = obj["time"]?.jsonPrimitive?.content ?: ""
                            val valInt = obj["value"]?.jsonPrimitive?.intOrNull ?: 0
                            if (time.isNotBlank() && valInt > 0) time to valInt else null
                        } ?: emptyList()
                        restingHr = root["activities-heart"]?.jsonArray?.getOrNull(0)?.jsonObject?.get("value")?.jsonObject?.get("restingHeartRate")?.jsonPrimitive?.intOrNull ?: 0
                    }
                }

                // Fetch Calories for that day
                val calRequest = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1/user/-/activities/date/$date.json")
                    .header("Authorization", "Bearer $token")
                    .build()
                
                var cals = 0
                client.newCall(calRequest).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        val root = json.parseToJsonElement(body).jsonObject
                        cals = root["summary"]?.jsonObject?.get("caloriesOut")?.jsonPrimitive?.intOrNull ?: 0
                    }
                }
                
                if (hrList.isNotEmpty() || cals > 0) {
                    Triple(hrList, restingHr, cals)
                } else null
            } catch (e: Exception) { null }
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
                
                val token = preferences.fitbitToken.first()
                val hasHC = healthConnectManager.hasAllPermissions()
                if (hasHC || token.isNotBlank()) {
                    val isToday = targetDateStr == java.time.LocalDate.now().toString()
                    
                    val cloudSpO2Deferred = if (token.isNotBlank()) async { fetchSpO2FromCloud(token, targetDateStr) } else null
                    val cloudBrDeferred = if (token.isNotBlank()) async { fetchRespiratoryRateFromCloud(token, targetDateStr) } else null
                    val cloudHrvDeferred = if (token.isNotBlank()) async { fetchHrvFromCloud(token, targetDateStr) } else null
                    val cloudWeightDeferred = if (token.isNotBlank()) async { fetchWeightFromCloud(token, targetDateStr) } else null

                    val intradayHRDeferred = if (hasHC) async { healthConnectManager.readHeartRateIntraday(targetDateStr) } else null
                    val respRateDeferred = if (hasHC) async { healthConnectManager.readRespiratoryRate(targetDateStr) } else null
                    val oxySatDeferred = if (hasHC) async { healthConnectManager.readOxygenSaturation(targetDateStr) } else null
                    val rhrDeferred = if (hasHC) async { healthConnectManager.readRestingHeartRate(targetDateStr) } else null
                    val weightDeferred = if (hasHC) async { healthConnectManager.readLatestWeight(targetDateStr) } else null
                    
                    val cloudSpO2 = try { cloudSpO2Deferred?.await() } catch(e: Exception) { null }
                    val cloudBr = try { cloudBrDeferred?.await() } catch(e: Exception) { null }
                    val cloudHrv = try { cloudHrvDeferred?.await() } catch(e: Exception) { null }

                    val intradayHR = try { intradayHRDeferred?.await() } catch(e: Exception) { null } ?: emptyList()
                    val respRate = cloudBr ?: try { respRateDeferred?.await() } catch(e: Exception) { null }
                    val oxySat = cloudSpO2 ?: try { oxySatDeferred?.await() } catch(e: Exception) { null }
                    val rhr = try { rhrDeferred?.await() } catch(e: Exception) { null }
                    val cloudWeight = try { cloudWeightDeferred?.await() } catch(e: Exception) { null }
                    val profileWeight = try { preferences.userWeight.first() } catch(e: Exception) { 0f }
                    val weight = cloudWeight?.toFloat() 
                        ?: try { weightDeferred?.await() } catch(e: Exception) { null }
                        ?: if (profileWeight > 0f) profileWeight else null
                    
                    // HRV is only fetched for past dates — today shows an advisory note and has no end-of-day value yet
                    val hrvForDate: Double = cloudHrv ?: if (!isToday && hasHC) {
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
                    _state.update { it.copy(errorMessage = "Failed to sync metrics: ${e.message}") }
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
            val token = preferences.fitbitToken.first()
            
            if (!hasHC && token.isBlank()) return@launch

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

    private suspend fun fetchSleepFromCloud(token: String, date: String): SleepData? {
        return withContext(Dispatchers.IO) {
            val client = okhttp3.OkHttpClient()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            try {
                val request = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1.2/user/-/sleep/date/$date.json")
                    .header("Authorization", "Bearer $token")
                    .build()
                
                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        val root = json.parseToJsonElement(body).jsonObject
                        val sleep = root["sleep"]?.jsonArray?.getOrNull(0)?.jsonObject ?: return@use null
                        
                        val duration = sleep["duration"]?.jsonPrimitive?.intOrNull ?: 0
                        val efficiency = sleep["efficiency"]?.jsonPrimitive?.intOrNull ?: 0
                        val minAsleep = sleep["minutesAsleep"]?.jsonPrimitive?.intOrNull ?: 0
                        
                        // Parse levels for details
                        val summary = sleep["levels"]?.jsonObject?.get("summary")?.jsonObject
                        val deep = summary?.get("deep")?.jsonObject?.get("minutes")?.jsonPrimitive?.intOrNull ?: 0
                        val light = summary?.get("light")?.jsonObject?.get("minutes")?.jsonPrimitive?.intOrNull ?: 0
                        val rem = summary?.get("rem")?.jsonObject?.get("minutes")?.jsonPrimitive?.intOrNull ?: 0
                        val wake = summary?.get("wake")?.jsonObject?.get("minutes")?.jsonPrimitive?.intOrNull ?: 0

                        SleepData(
                            minutesAsleep = minAsleep,
                            timeInBed = duration / 60000,
                            deepMinutes = deep,
                            lightMinutes = light,
                            remMinutes = rem,
                            wakeMinutes = wake,
                            efficiency = efficiency
                        )
                    } else null
                }
            } catch (e: Exception) { null }
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
            _state.update { it.copy(isFitbitConnected = false) }
        }
    }

    fun onPermissionsGranted() {
        viewModelScope.launch {
            _state.update { it.copy(isConnected = true) }
            sync(force = true)
        }
    }

    fun connectFitbit(context: android.content.Context) {
        val clientId = "23TRPL"
        val redirectUri = "potscube://callback"
        val scope = "activity heartrate sleep profile weight oxygen_saturation respiratory_rate"
        val url = "https://www.fitbit.com/oauth2/authorize?response_type=code&client_id=$clientId&redirect_uri=${java.net.URLEncoder.encode(redirectUri, "UTF-8")}&scope=${java.net.URLEncoder.encode(scope, "UTF-8")}"
        
        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
        context.startActivity(intent)
    }

    fun exchangeCodeForToken(code: String) {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true) }
            try {
                val clientId = "23TRPL"
                val clientSecret = "ffd7cbb8199676bfe4a83dd718741e2f"
                val authHeader = android.util.Base64.encodeToString(
                    "$clientId:$clientSecret".toByteArray(),
                    android.util.Base64.NO_WRAP
                )

                val requestBody = okhttp3.FormBody.Builder()
                    .add("client_id", clientId)
                    .add("grant_type", "authorization_code")
                    .add("redirect_uri", "potscube://callback")
                    .add("code", code)
                    .build()

                val request = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/oauth2/token")
                    .header("Authorization", "Basic $authHeader")
                    .post(requestBody)
                    .build()

                withContext(Dispatchers.IO) {
                    val client = okhttp3.OkHttpClient()
                    client.newCall(request).execute().use { response ->
                        if (response.isSuccessful) {
                            val body = response.body?.string() ?: ""
                            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
                            val element = json.parseToJsonElement(body).jsonObject
                            val token = element["access_token"]?.jsonPrimitive?.content ?: ""
                            val refresh = element["refresh_token"]?.jsonPrimitive?.content ?: ""
                            
                            if (token.isNotBlank()) {
                                viewModelScope.launch {
                                    preferences.setFitbitToken(token)
                                    preferences.setFitbitRefreshToken(refresh)
                                    _state.update { it.copy(isFitbitConnected = true, isLoading = false) }
                                    sync()
                                }
                            }
                        } else {
                            _state.update { it.copy(isLoading = false, errorMessage = "Fitbit Auth Failed: ${response.message}") }
                        }
                    }
                }
            } catch (e: Exception) {
                _state.update { it.copy(isLoading = false, errorMessage = "Fitbit Login Error: ${e.message}") }
            }
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
        val token = preferences.fitbitToken.first()
        
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
                    sleepDurationMap[summary.date] = summary.minutesAsleep
                    deepSleepMap[summary.date] = summary.deepMinutes
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        
        // ── Get Fitbit Data ──
        if (token.isNotBlank()) {
            try {
                // Fetch Sleep list from Fitbit (contains stages and deep minutes)
                val client = okhttp3.OkHttpClient()
                val todayStr = today.toString()
                val sleepHistRequest = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1.2/user/-/sleep/list.json?beforeDate=$todayStr&sort=desc&offset=0&limit=$resolvedDays")
                    .header("Authorization", "Bearer $token")
                    .build()
                
                client.newCall(sleepHistRequest).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        val root = json.parseToJsonElement(body).jsonObject
                        val sleepArray = root["sleep"]?.jsonArray ?: emptyList()
                        sleepArray.forEach { el ->
                            val obj = el.jsonObject
                            val date = obj["dateOfSleep"]?.jsonPrimitive?.content ?: ""
                            val minAsleep = obj["minutesAsleep"]?.jsonPrimitive?.intOrNull ?: 0
                            val summary = obj["levels"]?.jsonObject?.get("summary")?.jsonObject
                            val deep = summary?.get("deep")?.jsonObject?.get("minutes")?.jsonPrimitive?.intOrNull ?: 0
                            if (date.isNotBlank() && minAsleep > 0) {
                                sleepDurationMap[date] = minAsleep
                                deepSleepMap[date] = deep
                            }
                        }
                    }
                }
                
                // Fitbit heart rate / resting HR fallback
                val limitDays = if (days == -1) 365 else days // Fitbit heart rate 6m URL or daysd.json (limit to 365 days max for fallback)
                val hrHistRequest = okhttp3.Request.Builder()
                    .url("https://api.fitbit.com/1/user/-/activities/heart/date/today/${limitDays}d.json")
                    .header("Authorization", "Bearer $token")
                    .build()
                
                client.newCall(hrHistRequest).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string() ?: ""
                        val root = json.parseToJsonElement(body).jsonObject
                        root["activities-heart"]?.jsonArray?.forEach { el ->
                            val obj = el.jsonObject
                            val date = obj["dateTime"]?.jsonPrimitive?.content ?: ""
                            val valObj = obj["value"]?.jsonObject
                            val rhr = valObj?.get("restingHeartRate")?.jsonPrimitive?.intOrNull ?: 0
                            if (date.isNotBlank() && rhr > 0) {
                                if (!avgHrMap.containsKey(date)) {
                                    avgHrMap[date] = rhr
                                }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
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
                e.printStackTrace()
            } finally {
                _isExportingCsv.value = false
            }
        }
    }
}
