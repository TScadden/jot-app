package com.notel.notel.data.repository

import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.research.FlareForecast
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.LocalDate
import java.time.ZoneId
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Assembles a [FlareForecast.Forecast] from Tabs' existing data sources.
 *
 * Cache-first: the phone maintains per-day Biometrics insight payloads
 * (DataStore `aiInsights`, type "Biometrics", id "biometrics_<date>_v6")
 * carrying {sleepMins, spikeCount, hrv, sleepDebt, ...} for recent days — the
 * same source ClinicalReportDataCollector reads. Symptom slope comes from
 * log_entries (Symptoms category id 1). If Health Connect permission is
 * granted and caches are empty, falls back to direct Health Connect reads
 * for HRV and HR spikes.
 */
@Singleton
class FlareForecastRepository @Inject constructor(
    private val preferences: NotelPreferences,
    private val logEntryDao: LogEntryDao,
    private val healthConnectManager: com.notel.notel.data.healthconnect.HealthConnectManager
) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun computeForecast(): FlareForecast.Forecast {
        val biometrics = readBiometricsLastDays(7)

        // 1. HRV trend: latest day's hrv vs 7-day personal mean.
        var hrvFraction: Double? = null
        val hrvSeries = biometrics.mapNotNull { (date, payload) ->
            val hrv = payload["hrv"]?.jsonPrimitive?.doubleOrNull ?: 0.0
            if (hrv > 0.0) date to hrv else null
        }.sortedBy { it.first }
        if (hrvSeries.size >= 3) {
            val latest = hrvSeries.last().second
            val mean = hrvSeries.map { it.second }.average()
            if (mean > 0) hrvFraction = latest / mean
        }
        if (hrvFraction == null) {
            hrvFraction = hrvFromHealthConnect()
        }

        // 2. Sleep debt: the latest day's computed 7-day debt.
        var sleepDebt: Double? = null
        val latestBiometrics = biometrics.maxByOrNull { it.first }
        latestBiometrics?.second?.get("sleepDebt")?.jsonPrimitive?.doubleOrNull?.let { raw ->
            // sleepDebt is stored negative (debt) in LogRepository; normalize to positive minutes.
            sleepDebt = kotlin.math.abs(raw)
        }

        // 3. HR-spike frequency: per-day spike counts for the last 7 days.
        var spikeCounts = biometrics.mapNotNull { (_, payload) ->
            payload["spikeCount"]?.jsonPrimitive?.intOrNull
        }.takeLast(7)
        if (spikeCounts.size < 3) {
            spikeCounts = spikesFromHealthConnect()
        }

        // 4. Symptom slope: Symptoms-category entries last 3 days vs previous 3 days.
        val symptomsCategoryId = 1
        val zone = ZoneId.systemDefault()
        val todayStart = LocalDate.now().atStartOfDay(zone).toInstant().toEpochMilli()
        val dayMs = 24L * 60 * 60 * 1000
        val recent3 = logEntryDao.getCategoryEntryCountInRange(
            symptomsCategoryId, todayStart - 3 * dayMs, todayStart + dayMs
        )
        val previous3 = logEntryDao.getCategoryEntryCountInRange(
            symptomsCategoryId, todayStart - 6 * dayMs, todayStart - 3 * dayMs
        )

        return FlareForecast.compute(
            FlareForecast.FactorInput(
                hrvLatestFraction = hrvFraction,
                sleepDebtMinutes = sleepDebt,
                spikeCountsLast7Days = spikeCounts.takeIf { it.size >= 3 },
                symptomCounts = recent3 to previous3
            )
        )
    }

    private suspend fun readBiometricsLastDays(days: Int): List<Pair<String, kotlinx.serialization.json.JsonObject>> {
        return try {
            val minDate = LocalDate.now().minusDays(days.toLong()).toString()
            val raw = preferences.aiInsights.first()
            if (raw.isBlank()) return emptyList()
            json.decodeFromString<List<com.notel.notel.data.local.entity.AiInsight>>(raw)
                .filter { it.type == "Biometrics" && it.id.endsWith("_v6") }
                .mapNotNull { insight ->
                    val date = insight.id.removePrefix("biometrics_").removeSuffix("_v6")
                    if (date < minDate) return@mapNotNull null
                    val obj = try { json.parseToJsonElement(insight.text).jsonObject } catch (e: Exception) { null }
                        ?: return@mapNotNull null
                    date to obj
                }
                .sortedBy { it.first }
        } catch (e: Exception) { emptyList() }
    }

    private suspend fun hrvFromHealthConnect(): Double? {
        return try {
            if (!healthConnectManager.hasAllPermissions()) return null
            val series = healthConnectManager.readHeartRateVariability(days = 7)
            val vals = series.filter { it.second > 0 }.sortedBy { it.first }.map { it.second }
            if (vals.size < 3) return null
            val latest = vals.last()
            val mean = vals.average()
            if (mean > 0) latest / mean else null
        } catch (e: Exception) { null }
    }

    private suspend fun spikesFromHealthConnect(): List<Int> {
        return try {
            if (!healthConnectManager.hasAllPermissions()) return emptyList()
            healthConnectManager.readHistoricalHeartRateWithSpikes(days = 7)
                .sortedBy { it.date }
                .map { it.spikeCount }
        } catch (e: Exception) { emptyList() }
    }
}
