package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import com.google.android.gms.tasks.Task
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.util.Locale
import kotlin.coroutines.resume
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.time.LocalDate
import javax.inject.Inject

data class TodayMetricsState(
    val isLoading: Boolean = false,
    val activeCalories: Int = 0,
    val sleepMinutes: Int = 0,
    val jotCountDaily: Int = 0,
    val sleepDebtMins: Int = 0,
    val sleepDebtHistory: List<Triple<String, Double, Double>> = emptyList(),
    val selectedDate: String = LocalDate.now().toString(),
    val isHealthConnected: Boolean = true,
    val weather: WeatherState = WeatherState(),
    val weatherLoading: Boolean = false,
    // True only when a weather fetch just failed while a VPN was the active
    // network. The Current Location sheet shows a VPN-specific unavailable
    // state instead of the generic one. Never used to nag outside a fetch.
    val weatherVpnBlocked: Boolean = false,
    // True when the in-app location rationale card should be shown. The system
    // permission prompt only ever fires from the user's explicit tap on it.
    val showLocationRationale: Boolean = false,
    val avgHeartRate: Int = 0,
    val currentStreak: Int = 0,
    val bestStreak: Int = 0,
    val error: String? = null
)

data class WeatherState(
    val temp: Int = 0,
    val condition: String = "Clear",
    val uvIndex: Double = 0.0,
    val icon: String = "01d",
    val locationName: String = "Current Location",
    val unit: String = "F",
    val humidity: Int = 0,
    val windSpeed: Double = 0.0,
    val pressure: Double = 0.0,
    // true only when a fetch completed with real provider data.
    // Never render the numeric defaults as if they were real readings.
    val loaded: Boolean = false
)

@HiltViewModel
class TodayMetricsViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences,
    private val syncManager: com.notel.notel.data.sync.SyncManager,
    @ApplicationContext private val appContext: Context
) : ViewModel() {

    private val _uiState = MutableStateFlow(TodayMetricsState())
    val uiState = _uiState.asStateFlow()
    private val weatherApi = com.notel.notel.data.remote.WeatherApi()

    private var lastKnownLat: Double? = null
    private var lastKnownLon: Double? = null
    private var lastKnownCity: String? = null

    init {
        // Observe streak data
        viewModelScope.launch {
            preferences.currentStreak.collect { s -> _uiState.update { it.copy(currentStreak = s) } }
        }
        viewModelScope.launch {
            preferences.bestStreak.collect { s -> _uiState.update { it.copy(bestStreak = s) } }
        }
        viewModelScope.launch {
            // Re-update metrics whenever selectedDate, HR history, calorie history, sleep history changes
            combine(
                _uiState.map { it.selectedDate }.distinctUntilChanged(),
                preferences.historicalHeartRate,
                preferences.historicalCalories,
                preferences.historicalSleep,
                preferences.todayAwakeAvgHr,
                logRepository.getAllEntries()
            ) { array ->
                val date = array[0] as String
                val hrStr = array[1] as String
                val calStr = array[2] as String
                val sleepStr = array[3] as String
                val todayAwake = array[4] as Int
                // array[5] is logEntries

                val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
                val today = LocalDate.now().toString()

                // 1. Heart Rate
                var hr = 0
                if (date == today && todayAwake > 0) {
                    hr = todayAwake
                } else {
                    try {
                        val points = json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(hrStr)
                        hr = points.find { it.date == date }?.value?.toInt() ?: 0
                    } catch(e: Exception) {}
                }

                // 2. Calories
                var cal = 0
                try {
                    val points = json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(calStr)
                    cal = points.find { it.date == date }?.value?.toInt() ?: 0
                } catch(e: Exception) {}

                // 3. Sleep & Debt
                var sleep = 0
                var debt = 0.0
                var debtHistory = emptyList<Triple<String, Double, Double>>()
                try {
                    val points = json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(sleepStr)
                    sleep = points.find { it.date == date }?.value?.toInt() ?: 0

                    var runningDebt = 0.0
                    val targetHours = 8.0
                    val sortedPoints = points.sortedBy { it.date }

                    val historyList = mutableListOf<Triple<String, Double, Double>>()
                    val relevantPoints = sortedPoints.filter { it.date <= date }.takeLast(10)

                    relevantPoints.forEach { pt ->
                        val actualHours = pt.value / 60.0
                        if (actualHours < targetHours) {
                            runningDebt += (targetHours - actualHours)
                        } else {
                            val surplus = actualHours - targetHours
                            runningDebt -= Math.min(surplus, 1.5)
                        }
                        runningDebt = Math.max(0.0, runningDebt)
                        historyList.add(Triple(pt.date, actualHours - targetHours, -runningDebt))
                    }
                    debt = -runningDebt
                    debtHistory = historyList
                } catch(e: Exception) {}

                // 4. Jots
                val count = if (date == today) {
                    logRepository.getTodayJotCount()
                } else {
                    val start = LocalDate.parse(date).atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
                    val end = start + (24 * 60 * 60 * 1000L)
                    logRepository.getJotCountInRange(start, end)
                }

                MetricsUpdate(
                    hr = hr,
                    cal = cal,
                    sleep = sleep,
                    jots = count,
                    debtMins = (debt * 60).toInt(),
                    debtHistory = debtHistory
                )
            }.collect { update ->
                _uiState.update { it.copy(
                    avgHeartRate = update.hr,
                    activeCalories = update.cal,
                    sleepMinutes = update.sleep,
                    jotCountDaily = update.jots,
                    sleepDebtMins = update.debtMins,
                    sleepDebtHistory = update.debtHistory
                ) }
            }
        }
        selectDay(LocalDate.now().toString())
        refreshWeather()
        maybeShowLocationRationale()
    }

    private data class MetricsUpdate(
        val hr: Int,
        val cal: Int,
        val sleep: Int,
        val jots: Int,
        val debtMins: Int,
        val debtHistory: List<Triple<String, Double, Double>>
    )

    fun refresh(force: Boolean = false) {
        val dateStr = _uiState.value.selectedDate
        viewModelScope.launch {
            try {
                _uiState.update { it.copy(isLoading = true) }
                logRepository.getDailyStatsSummary(dateStr, forceRefresh = true)
                syncManager.syncAllData()
            } catch (e: Exception) {
            } finally {
                _uiState.update { it.copy(isLoading = false) }
            }
        }
    }

    fun selectDay(dateStr: String) {
        val today = LocalDate.now().toString()
        _uiState.update { it.copy(selectedDate = dateStr, isLoading = true) }

        viewModelScope.launch {
            try {
                logRepository.getDailyStatsSummary(dateStr, forceRefresh = (dateStr == today))

                _uiState.update { it.copy(isLoading = false) }
            } catch (e: Exception) {
                _uiState.update { it.copy(isLoading = false) }
            }
        }
    }

    fun updateLocation(lat: Double, lon: Double, city: String) {
        lastKnownLat = lat
        lastKnownLon = lon
        lastKnownCity = city
        viewModelScope.launch {
            preferences.setLastKnownLocation(lat, lon, city)
            fetchWeather()
        }
    }

    /** True when the app may read approximate device location for weather. */
    fun hasWeatherLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Entry point for weather loading: GPS first when permitted, otherwise the
     * saved-location / IP path. The IP fallback and the honest unavailable
     * state are untouched; GPS is strictly an upgrade.
     */
    private fun refreshWeather() {
        if (hasWeatherLocationPermission()) {
            fetchGpsLocation()
        } else {
            fetchWeather()
        }
    }

    /**
     * Shows the in-app rationale card (rendered by the screen) when location
     * has never been asked for. The system prompt only fires from the user's
     * explicit tap on "Share location", never automatically.
     */
    private fun maybeShowLocationRationale() {
        viewModelScope.launch {
            if (!hasWeatherLocationPermission() && !preferences.weatherLocationPromptSeen.first()) {
                _uiState.update { it.copy(showLocationRationale = true) }
            }
        }
    }

    fun dismissLocationRationale() {
        viewModelScope.launch {
            preferences.setWeatherLocationPromptSeen(true)
            _uiState.update { it.copy(showLocationRationale = false) }
        }
    }

    fun onLocationPermissionResult(granted: Boolean) {
        viewModelScope.launch {
            preferences.setWeatherLocationPromptSeen(true)
            _uiState.update { it.copy(showLocationRationale = false) }
            if (granted) {
                fetchGpsLocation()
            }
            // Denied: weather keeps working through the IP fallback path that
            // already ran at init. No nagging, no fake data.
        }
    }

    /**
     * One-shot GPS fix for weather, then the normal fetch. Any failure
     * (timeout, no fix, Geocoder down) falls through to fetchWeather(), which
     * keeps the IP fallback and the honest unavailable state.
     */
    private fun fetchGpsLocation() {
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            // Show the skeleton (not the honest unavailable state) while the
            // one-shot fix is in flight; fetchWeather() clears it in finally.
            _uiState.update { it.copy(weatherLoading = true) }
            try {
                if (!hasWeatherLocationPermission()) {
                    fetchWeather()
                    return@launch
                }
                val client = LocationServices.getFusedLocationProviderClient(appContext)
                var location: Location? = null
                try {
                    location = withTimeout(GPS_TIMEOUT_MS) {
                        awaitLocationTask(
                            client.getCurrentLocation(
                                Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                                CancellationTokenSource().token
                            )
                        )
                    }
                } catch (e: Exception) {
                    // Timeout or cancellation: fall through to lastLocation.
                }
                if (location == null) {
                    location = awaitLocationTask(client.lastLocation)
                }
                if (location != null) {
                    updateLocation(
                        location.latitude,
                        location.longitude,
                        geocodeCity(location.latitude, location.longitude)
                    )
                } else {
                    fetchWeather()
                }
            } catch (e: SecurityException) {
                // Permission revoked mid-flight: IP fallback path.
                fetchWeather()
            }
        }
    }

    private suspend fun awaitLocationTask(task: Task<Location?>): Location? =
        suspendCancellableCoroutine { cont ->
            task.addOnSuccessListener { cont.resume(it) }
                .addOnFailureListener { cont.resume(null) }
        }

    @Suppress("DEPRECATION") // Blocking Geocoder works on all API levels; called on Dispatchers.IO.
    private fun geocodeCity(lat: Double, lon: Double): String {
        return try {
            Geocoder(appContext, Locale.getDefault())
                .getFromLocation(lat, lon, 1)
                ?.firstOrNull()
                ?.locality
                ?: "Current Location"
        } catch (e: Exception) {
            "Current Location"
        }
    }

    private fun fetchWeather() {
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            _uiState.update { it.copy(weatherLoading = true, weatherVpnBlocked = false) }
            var ok = false
            try {
                val lat = lastKnownLat ?: preferences.lastKnownLat.first().takeIf { it != 0.0 }
                val lon = lastKnownLon ?: preferences.lastKnownLon.first().takeIf { it != 0.0 }
                val city = lastKnownCity ?: preferences.lastKnownCity.first()

                weatherApi.getDetailedWeather(lat, lon, city)?.let { info ->
                    ok = true
                    _uiState.update { it.copy(
                        weather = WeatherState(
                            temp = info.temp,
                            condition = info.condition,
                            uvIndex = info.uvIndex,
                            icon = info.icon,
                            locationName = info.locationName,
                            unit = info.unit,
                            humidity = info.humidity,
                            windSpeed = info.windSpeed,
                            pressure = info.pressure,
                            loaded = true
                        )
                    ) }
                }
            } finally {
                // A failed fetch while a VPN is the active network is almost
                // certainly the VPN (e.g. Tailscale) blocking the weather call,
                // not a weather outage: say so in the sheet instead of the
                // generic error. Needs no new permissions (ACCESS_NETWORK_STATE).
                val vpnFailed = !ok && isVpnActive()
                _uiState.update { it.copy(weatherLoading = false, weatherVpnBlocked = vpnFailed) }
            }
        }
    }

    /**
     * True when the device's active network routes through a VPN
     * (Tailscale included). Checked only when a weather fetch has failed, so
     * VPN users who never open weather are never nagged.
     */
    private fun isVpnActive(): Boolean {
        val connectivity = appContext.getSystemService(Context.CONNECTIVITY_SERVICE)
            as android.net.ConnectivityManager
        val caps = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            ?: return false
        return caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)
    }

    fun retryWeather() {
        refreshWeather()
    }

    companion object {
        // One GPS fix must never hold weather hostage: past this, IP fallback runs.
        private const val GPS_TIMEOUT_MS = 12_000L
    }
}
