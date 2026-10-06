package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.dao.MedicationDao
import com.notel.notel.data.local.entity.AiInsight
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.GeminiService
import com.notel.notel.data.remote.PressureTrend
import com.notel.notel.data.remote.WeatherApi
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.LocalDate
import javax.inject.Inject

/**
 * AI morning briefing: a concise daily digest card. Yesterday's key numbers,
 * today's weather + pressure outlook, medication reminders, ONE AI-generated
 * insight (via the existing GeminiService advice endpoint — no new server
 * endpoint), and one deterministic energy suggestion.
 *
 * Cached per day in DataStore; regenerates on refresh or when the date
 * changes. Concise by design — the founder hates bloated summaries.
 */
@Serializable
data class MorningBriefing(
    val date: String,
    val yesterdayLines: List<String> = emptyList(),
    val weatherLine: String = "",
    val pressureLine: String = "",
    val medLines: List<String> = emptyList(),
    val aiInsight: String = "",
    val energySuggestion: String = "",
    val generatedAt: Long = 0L
)

sealed class MorningBriefingUiState {
    object Loading : MorningBriefingUiState()
    data class Ready(val briefing: MorningBriefing) : MorningBriefingUiState()
    data class Error(val message: String) : MorningBriefingUiState()
}

@HiltViewModel
class MorningBriefingViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    private val logEntryDao: LogEntryDao,
    private val medicationDao: MedicationDao,
    private val geminiService: GeminiService
) : ViewModel() {

    private val weatherApi = WeatherApi()
    private val json = Json { ignoreUnknownKeys = true }

    private val _state = MutableStateFlow<MorningBriefingUiState>(MorningBriefingUiState.Loading)
    val state: StateFlow<MorningBriefingUiState> = _state.asStateFlow()

    init {
        load(force = false)
    }

    fun refresh() = load(force = true)

    private fun load(force: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            _state.value = MorningBriefingUiState.Loading
            try {
                val today = LocalDate.now().toString()
                if (!force) {
                    val cached = readCache()
                    if (cached != null && cached.date == today) {
                        _state.value = MorningBriefingUiState.Ready(cached)
                        return@launch
                    }
                }
                val briefing = buildBriefing(today)
                writeCache(briefing)
                _state.value = MorningBriefingUiState.Ready(briefing)
            } catch (e: Exception) {
                val cached = readCache()
                if (cached != null) _state.value = MorningBriefingUiState.Ready(cached)
                else _state.value = MorningBriefingUiState.Error("Could not build the briefing. Try again later.")
            }
        }
    }

    private suspend fun buildBriefing(today: String): MorningBriefing {
        val yesterday = LocalDate.now().minusDays(1).toString()
        val payload = readBiometricsPayload(yesterday)

        val yesterdayLines = mutableListOf<String>()
        val sleepMins = payload?.get("sleepMins")?.jsonPrimitive?.doubleOrNull ?: 0.0
        if (sleepMins > 0) yesterdayLines.add("Sleep: ${formatSleep(sleepMins)}")
        val spikes = payload?.get("spikeCount")?.jsonPrimitive?.intOrNull ?: 0
        yesterdayLines.add("HR spikes: $spikes")
        val hrv = payload?.get("hrv")?.jsonPrimitive?.doubleOrNull ?: 0.0
        if (hrv > 0) yesterdayLines.add("HRV: ${hrv.toInt()} ms")
        val awakeAvg = payload?.get("awakeAvg")?.jsonPrimitive?.doubleOrNull ?: 0.0
        if (awakeAvg > 0) yesterdayLines.add("Avg awake HR: ${awakeAvg.toInt()} bpm")

        // Weather + pressure outlook
        val lat = preferences.lastKnownLat.first().takeIf { it != 0.0 }
        val lon = preferences.lastKnownLon.first().takeIf { it != 0.0 }
        val city = preferences.lastKnownCity.first()
        var weatherLine = ""
        var pressureLine = ""
        if (lat != null && lon != null) {
            weatherApi.getDetailedWeather(lat, lon, city)?.let { w ->
                weatherLine = "${w.temp}°${w.unit} ${w.condition.lowercase()} in ${w.locationName}"
            }
            weatherApi.getPressureOutlook(lat, lon)?.let { p ->
                pressureLine = when (p.trend) {
                    PressureTrend.RISING -> "Pressure rising over the next 24h"
                    PressureTrend.FALLING -> "Pressure falling over the next 24h (migraine watch)"
                    PressureTrend.STEADY -> "Pressure steady over the next 24h"
                    PressureTrend.UNKNOWN -> ""
                }
            }
        }

        // Medication reminders: active meds still due today
        val meds = medicationDao.getAllMedications().first()
            .filter { !it.isArchived && !it.isDeleted }
        val medLines = meds.map { med ->
            val dose = med.dose.ifBlank { "" }
            "${med.name}${if (dose.isNotBlank()) " $dose" else ""} (${med.frequency})"
        }

        // Deterministic energy suggestion from the numbers
        val energySuggestion = energySuggestion(
            sleepMins = sleepMins,
            sleepDebt = payload?.get("sleepDebt")?.jsonPrimitive?.doubleOrNull,
            hrv = hrv,
            hrvMean = payload?.get("hrvMean")?.jsonPrimitive?.doubleOrNull
        )

        // One AI insight via the existing pipeline (tight prompt, capped length)
        val aiInsight = fetchAiInsight(yesterdayLines, weatherLine, pressureLine)

        return MorningBriefing(
            date = today,
            yesterdayLines = yesterdayLines,
            weatherLine = weatherLine,
            pressureLine = pressureLine,
            medLines = medLines,
            aiInsight = aiInsight,
            energySuggestion = energySuggestion,
            generatedAt = System.currentTimeMillis()
        )
    }

    private suspend fun fetchAiInsight(
        yesterdayLines: List<String>,
        weatherLine: String,
        pressureLine: String
    ): String {
        return try {
            val recent = logEntryDao.getRecentEntriesAll(limit = 20)
            val fitbitData = buildString {
                appendLine("YESTERDAY (informational summary, not advice):")
                yesterdayLines.forEach { appendLine("- $it") }
                if (weatherLine.isNotBlank()) appendLine("Today: $weatherLine")
                if (pressureLine.isNotBlank()) appendLine(pressureLine)
                appendLine()
                appendLine("Respond with at most TWO sentences: one informational observation about the last 24 hours of this person's own tracked data. Do not diagnose any condition. Do not give medical advice or treatment recommendations.")
            }
            val result = geminiService.getAdvice(
                recentEntries = recent,
                categories = mapOf(1 to "Symptoms"),
                fitbitData = fitbitData,
                weatherContext = weatherLine.ifBlank { null }
            )
            result.getOrNull()?.trim()?.take(400) ?: ""
        } catch (e: Exception) { "" }
    }

    companion object {
        /** Pure logic — used directly by Tess's verification. */
        fun energySuggestion(
            sleepMins: Double,
            sleepDebt: Double?,
            hrv: Double,
            hrvMean: Double?
        ): String {
            val debtHours = (sleepDebt ?: 0.0).let { kotlin.math.abs(it) } / 60.0
            val hrvRatio = if (hrv > 0 && hrvMean != null && hrvMean > 0) hrv / hrvMean else 1.0
            val shortNight = sleepMins > 0 && sleepMins < 360
            val highDebt = debtHours >= 3.0
            val lowHrv = hrvRatio < 0.85
            return when {
                shortNight && (highDebt || lowHrv) ->
                    "Keep it gentle today: a short night plus ${if (highDebt) "sleep debt" else "low HRV"} suggests pacing and rest."
                highDebt || lowHrv ->
                    "A steady, low-demand day fits today's recovery picture."
                else ->
                    "No recovery flags this morning — pace as usual and log as you go."
            }
        }

        fun formatSleep(sleepMins: Double): String {
            val h = (sleepMins / 60).toInt()
            val m = (sleepMins % 60).toInt()
            return "${h}h ${m}m"
        }
    }

    private suspend fun readBiometricsPayload(date: String): kotlinx.serialization.json.JsonObject? {
        return try {
            val raw = preferences.aiInsights.first()
            if (raw.isBlank()) return null
            val insight = json.decodeFromString<List<AiInsight>>(raw)
                .firstOrNull { it.type == "Biometrics" && it.id == "biometrics_${date}_v6" }
                ?: return null
            json.parseToJsonElement(insight.text).jsonObject
        } catch (e: Exception) { null }
    }

    private suspend fun readCache(): MorningBriefing? {
        return try {
            val raw = preferences.morningBriefingCache.first()
            if (raw.isBlank()) null else json.decodeFromString<MorningBriefing>(raw)
        } catch (e: Exception) { null }
    }

    private suspend fun writeCache(briefing: MorningBriefing) {
        try { preferences.setMorningBriefingCache(json.encodeToString(briefing)) } catch (e: Exception) { }
    }
}
