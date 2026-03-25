package com.notel.notel.ui.viewmodel

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.healthconnect.HealthConnectManager
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
    val heartRateData: List<Pair<String, Int>> = emptyList(), // time String "12:30:00" -> HR int
    val averageHeartRate: Int = 0,
    val latestHeartRate: Int = 0,
    val latestHeartRateTime: String = "",
    val connectedDevices: List<String> = emptyList(), // Can default to ["Health Connect"]
    val historicalHeartRate: List<Pair<String, Int>> = emptyList(), // "YYYY-MM-DD" -> HR
    val historicalSleep: List<Pair<String, Int>> = emptyList(), // "YYYY-MM-DD" -> Minutes Asleep
    val historicalCalories: List<Pair<String, Int>> = emptyList(), // "YYYY-MM-DD" -> Calories
    val sleepData: SleepData? = null,
    val selectedSleepDate: String = "today",
    val selectedHeartRateDate: String = "today",
    val caloriesBurned: Int = 0,
    val isFitbitConnected: Boolean = false,
    val errorMessage: String? = null
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
                preferences.fitbitToken.collect { token ->
                    _state.update { it.copy(isFitbitConnected = token.isNotBlank()) }
                }
            } catch (e: Exception) {
                // Ignore background pref errors
            }
        }
        viewModelScope.launch {
            try {
                if (healthConnectManager.hasAllPermissions()) {
                    _state.update { it.copy(isConnected = true) }
                    sync(force = true)
                } else {
                    _state.update { it.copy(isConnected = false) }
                }
            } catch (e: Exception) {
                _state.update { it.copy(errorMessage = "Init Sync failed") }
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
                        syncFromHealthConnect()
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
    }

    private suspend fun syncFromHealthConnect() = coroutineScope {
         val intradayHRDeferred = async { healthConnectManager.readHeartRateIntraday(_state.value.selectedHeartRateDate) }
         val avgHRDeferred = async { healthConnectManager.readHeartRateAverage(_state.value.selectedHeartRateDate) }
         val histHRDeferred = async { healthConnectManager.readHistoricalHeartRate() }
         val histSleepDeferred = async { healthConnectManager.readHistoricalSleep() }
         val sleepDeferred = async { healthConnectManager.readSleepSession(_state.value.selectedSleepDate) }
         val activeCalDeferred = async { healthConnectManager.readActiveCalories(_state.value.selectedHeartRateDate) }
         val histCalDeferred = async { healthConnectManager.readHistoricalCalories() }

         val intradayHR = try { intradayHRDeferred.await() } catch(e: Exception) { emptyList() }
         val avgHR = try { avgHRDeferred.await() } catch(e: Exception) { 0 }
         val histHR = try { histHRDeferred.await() } catch(e: Exception) { emptyList() }
         val histSleep = try { histSleepDeferred.await() } catch(e: Exception) { emptyList() }
         val sleepData = try { sleepDeferred.await() } catch(e: Exception) { null }
         val activeCal = try { activeCalDeferred.await() } catch(e: Exception) { 0 }
         val histCal = try { histCalDeferred.await() } catch(e: Exception) { emptyList() }

         var latest = intradayHR.lastOrNull()?.second ?: 0
         val latestTime = intradayHR.lastOrNull()?.first ?: ""

         val formattedTime = if (latestTime.isNotBlank()) {
             try {
                 val parser = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
                 val formatter = java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault())
                 parser.parse(latestTime)?.let { formatter.format(it) } ?: latestTime
             } catch(e: Exception) { latestTime }
         } else ""

         _state.update { 
             it.copy(
                 heartRateData = intradayHR,
                 averageHeartRate = avgHR,
                 latestHeartRate = latest,
                 latestHeartRateTime = formattedTime,
                 historicalHeartRate = histHR,
                 historicalSleep = histSleep,
                 historicalCalories = histCal,
                 sleepData = sleepData,
                 caloriesBurned = activeCal,
                 errorMessage = if (latest == 0 && avgHR == 0) "No recent HC data found" else null
             )
         }

         // Save to preferences for long-term AI report access
         val json = Json { ignoreUnknownKeys = true }
         preferences.setHistoricalHeartRate(json.encodeToString(histHR.map { BiomarkerPoint(it.first, it.second) }))
         preferences.setHistoricalSleep(json.encodeToString(histSleep.map { BiomarkerPoint(it.first, it.second) }))
         preferences.setHistoricalCalories(json.encodeToString(histCal.map { BiomarkerPoint(it.first, it.second) }))
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
            
            var intradayHR: List<Pair<String, Int>> = emptyList()
            var avgHR = 0
            var activeCal = 0

            if (hasHC) {
                intradayHR = healthConnectManager.readHeartRateIntraday(date)
                avgHR = healthConnectManager.readHeartRateAverage(date)
                activeCal = healthConnectManager.readActiveCalories(date)
            }

            
            var latest = intradayHR.lastOrNull()?.second ?: 0
            val latestTime = intradayHR.lastOrNull()?.first ?: ""

            val formattedTime = if (latestTime.isNotBlank()) {
                try {
                    val parser = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
                    val formatter = java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault())
                    parser.parse(latestTime)?.let { formatter.format(it) } ?: latestTime
                } catch(e: Exception) { latestTime }
            } else ""

            _state.update { 
                it.copy(
                    isLoading = false,
                    heartRateData = intradayHR,
                    averageHeartRate = avgHR,
                    latestHeartRate = latest,
                    latestHeartRateTime = formattedTime,
                    caloriesBurned = activeCal,
                    errorMessage = if (intradayHR.isEmpty() && activeCal == 0) "No data found for this date." else null
                )
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

    fun fetchSleepForDate(date: String) {
        viewModelScope.launch {
            val hasHC = healthConnectManager.hasAllPermissions()
            val token = preferences.fitbitToken.first()
            
            if (!hasHC && token.isBlank()) return@launch

            _state.update { it.copy(isLoading = true, errorMessage = null, selectedSleepDate = date) }
            
            var sleepData: SleepData? = null
            // Only fetch from Health Connect
            sleepData = healthConnectManager.readSleepSession(date)

            _state.update { 
                it.copy(
                    isLoading = false,
                    sleepData = sleepData,
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

    fun disconnect() {
        // Just clear the preference, or we can't truly disconnect Health Connect permissions easily,
        // but we can just set a local preference indicating we are ignoring it.
        viewModelScope.launch {
            preferences.setFitbitToken("") // legacy cleanup
            _state.update { it.copy(isConnected = false) }
        }
    }

    fun onPermissionsGranted() {
        viewModelScope.launch {
            _state.update { it.copy(isConnected = true) }
            sync()
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
}
