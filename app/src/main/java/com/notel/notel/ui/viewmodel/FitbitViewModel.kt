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
    val todayHRV: Double = 0.0
)


@HiltViewModel
class FitbitViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    val healthConnectManager: HealthConnectManager
) : ViewModel() {

    private val _state = MutableStateFlow(FitbitState(connectedDevices = listOf("Health Connect")))
    val state = _state.asStateFlow()

    private var lastSyncTime = 0L

    init {
        viewModelScope.launch {
            try {
                launch {
                    preferences.fitbitToken.collect { token ->
                        _state.update { it.copy(isFitbitConnected = token.isNotBlank()) }
                    }
                }
                launch {
                    val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
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
                    val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
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
                    val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
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
                    val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
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
            if (healthConnectManager.hasBasicPermissions()) {
                _state.update { it.copy(isConnected = true) }
                sync(force = false)
            } else {
                _state.update { it.copy(isConnected = false) }
            }
        } catch (e: Exception) {
            _state.update { it.copy(errorMessage = "Connection check failed") }
        }
    }

    fun navigateToWorstSpikeDay() {
        viewModelScope.launch {
            try {
                _state.update { it.copy(isLoading = true) }
                // Always do a live fetch — never rely on the DataStore cache for this
                val freshSpikes = healthConnectManager.readHistoricalHeartRateWithSpikes(180)
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
        if (_state.value.isLoading) return
        
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
                    fetchFromFitbitApi(token)
                }
            } catch (e: Exception) {
                _state.update { it.copy(errorMessage = "Sync failed: ${e.message}") }
            } finally {
                _state.update { it.copy(isLoading = false) }
            }
        }
    }    private suspend fun syncFromHealthConnect(fetchHistory: Boolean = false) = coroutineScope {
         val targetDate = if (_state.value.selectedKeyMetricsDate == "today") java.time.LocalDate.now().toString() else _state.value.selectedKeyMetricsDate
         
         // PHASE 1: Current Day Metrics (Instant Update)
         val intradayHRDeferred = async { healthConnectManager.readHeartRateIntraday(targetDate) }
         val avgHRDeferred = async { healthConnectManager.readHeartRateAverage(targetDate) }
         val sleepDeferred = async { healthConnectManager.readSleepSession(targetDate) }
         val activeCalDeferred = async { healthConnectManager.readActiveCalories(targetDate) }
         val hrvDeferred = async { healthConnectManager.readHeartRateVariability(days = 7) }

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
         val hrvData = try { hrvDeferred.await() } catch(e: Exception) { emptyList() }
         val currentHrv = hrvData.find { it.first == _state.value.selectedHeartRateDate }?.second ?: hrvData.lastOrNull()?.second ?: 0.0

         var latest = intradayHR.lastOrNull()?.second ?: 0
         val latestTime = intradayHR.lastOrNull()?.first ?: 0L

         val formattedTime = if (latestTime > 0) {
             try {
                 val formatter = java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault())
                 formatter.format(java.util.Date(latestTime))
             } catch(e: Exception) { latestTime.toString() }
         } else ""

         val respRate = healthConnectManager.readRespiratoryRate(targetDate) ?: 0.0
         val oxySat = healthConnectManager.readOxygenSaturation(targetDate) ?: 0.0
         val rhrValue = healthConnectManager.readRestingHeartRate(targetDate) ?: 0
         val weightVal = healthConnectManager.readLatestWeight(targetDate) ?: 0f
         val hrvTodayVal = healthConnectManager.readHeartRateVariability(days = 1).find { it.first == targetDate }?.second ?: 0.0

         // Immediate UI update for today's metrics
         _state.update { 
             it.copy(
                 heartRateData = intradayHR,
                 averageHeartRate = avgHR,
                 asleepHeartRate = asleepHR,
                 latestHeartRate = latest,
                 latestHeartRateTime = formattedTime,
                 sleepData = sleepData,
                 caloriesBurned = activeCal,
                 hrvData = hrvData,
                 currentHrv = currentHrv,
                 sleepDebtMins = calculateDebtAtDate(_state.value.selectedSleepDate, _state.value.historicalSleep),
                 respiratoryRate = respRate,
                 bloodOxygen = oxySat,
                 restingHeartRate = rhrValue,
                 weightPounds = weightVal,
                 todayHRV = hrvTodayVal,
                 errorMessage = if (latest == 0 && avgHR == 0) "No recent HC data found" else null
             )
         }
         if (_state.value.selectedHeartRateDate == "today" && avgHR > 0) {
              preferences.setTodayAwakeAvgHr(avgHR)
         }

         // PHASE 2: Historical Metrics (Background Background)
         if (fetchHistory) {
             val histHR = try { healthConnectManager.readHistoricalHeartRate(30) } catch(e: Exception) { _state.value.historicalHeartRate }
             val histSpikes = try { healthConnectManager.readHistoricalHeartRateWithSpikes(90) } catch(e: Exception) { _state.value.historicalSpikes }
             val histSleep = try { healthConnectManager.readHistoricalSleep(30) } catch(e: Exception) { _state.value.historicalSleep }
             val histCal = try { healthConnectManager.readHistoricalCalories(30) } catch(e: Exception) { _state.value.historicalCalories }

             _state.update { 
                 it.copy(
                     historicalHeartRate = histHR,
                     historicalSleep = histSleep,
                     historicalCalories = histCal,
                     historicalSpikes = histSpikes,
                     sleepDebtMins = calculateDebtAtDate(_state.value.selectedSleepDate, histSleep)
                 )
             }

             // Background persistence
             val json = Json { ignoreUnknownKeys = true }
             preferences.setHistoricalHeartRate(json.encodeToString(histHR.map { BiomarkerPoint(it.first, it.second) }))
             preferences.setHistoricalSleep(json.encodeToString(histSleep.map { BiomarkerPoint(it.first, it.second) }))
             preferences.setHistoricalCalories(json.encodeToString(histCal.map { BiomarkerPoint(it.first, it.second) }))
             preferences.setHistoricalHrSpikes(json.encodeToString(histSpikes))
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
                // Silently fail as this is a fallback
            }
        }
    }

    private fun <T> List<T>.firstBy(predicate: (T) -> Boolean): T? = firstOrNull(predicate)

    fun fetchHeartRateForDate(date: String) {
        viewModelScope.launch {
            val hasHC = healthConnectManager.hasAllPermissions()
            val token = preferences.fitbitToken.first()
            
            if (!hasHC && token.isBlank()) return@launch

            _state.update { it.copy(isLoading = true, errorMessage = null, selectedHeartRateDate = date) }
            
            var intradayHR: List<Pair<Long, Int>> = emptyList()
            var avgHR = 0
            var asleepHR = 0
            var activeCal = 0
            var currentHrv = 0.0

            if (hasHC) {
                intradayHR = healthConnectManager.readHeartRateIntraday(date)
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
                activeCal = healthConnectManager.readActiveCalories(date)
                val hrvList = healthConnectManager.readHeartRateVariability()
                currentHrv = hrvList.find { it.first == date }?.second ?: 0.0
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
                currentState.copy(
                    isLoading = false,
                    heartRateData = intradayHR,
                    averageHeartRate = avgHR,
                    asleepHeartRate = asleepHR,
                    latestHeartRate = latest,
                    latestHeartRateTime = formattedTime,
                    caloriesBurned = activeCal,
                    currentHrv = currentHrv,
                    // historicalSpikes is populated from the DataStore preferences flow in init{}
                    errorMessage = if (intradayHR.isEmpty() && activeCal == 0) "No data found for this date." else null
                )
            }
            if (date == "today" && avgHR > 0) {
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

    fun fetchMetricsForDate(date: String) {
        _state.update { it.copy(
            selectedKeyMetricsDate = date,
            selectedHeartRateDate = date,
            selectedSleepDate = date
        ) }
        sync(force = true)
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
        val scope = "activity heartrate sleep profile"
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
}
