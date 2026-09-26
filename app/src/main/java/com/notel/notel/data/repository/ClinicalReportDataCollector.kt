package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.HealthConnectCoordinator
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.KnowledgeDocumentDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.model.*
import com.notel.notel.data.preferences.NotelPreferences
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import java.time.LocalDate
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ClinicalReportDataCollector @Inject constructor(
    private val logEntryDao: LogEntryDao,
    private val knowledgeDocumentDao: KnowledgeDocumentDao,
    private val preferences: NotelPreferences,
    private val conditionRepository: ConditionRepository,
    private val bloodPressureRepository: BloodPressureRepository,
    private val healthConnectCoordinator: HealthConnectCoordinator,
    private val healthConnectManager: HealthConnectManager
) {

    suspend fun collectReportData(
        allCategories: List<Category>,
        last30DaysOnly: Boolean
    ): ClinicalReportData = coroutineScope {
        val now = System.currentTimeMillis()
        val daysToFetch = if (last30DaysOnly) 31 else 180
        val cutoff = if (last30DaysOnly) now - (30L * 24 * 60 * 60 * 1000) else 0L

        val rangeType = if (last30DaysOnly) ClinicalReportRangeType.LAST_30_DAYS else ClinicalReportRangeType.FULL
        val range = ClinicalReportRange(
            type = rangeType,
            startEpochMs = if (last30DaysOnly) cutoff else (now - (180L * 24 * 60 * 60 * 1000)),
            endEpochMs = now
        )

        val metadataMap = java.util.concurrent.ConcurrentHashMap<String, SectionMetadata>()

        // 1. Logs
        val logsDeferred = async {
            try {
                val entries = if (last30DaysOnly) {
                    logEntryDao.getRecentEntriesInRange(cutoff, now)
                } else {
                    logEntryDao.getRecentEntriesAll(limit = 2000)
                }
                metadataMap["logs"] = SectionMetadata("logs", DataSourceStatus.SUCCESS, entries.size)
                entries
            } catch (e: Exception) {
                metadataMap["logs"] = SectionMetadata("logs", DataSourceStatus.ERROR, 0, e.message)
                emptyList()
            }
        }

        // 2. User Profile
        val profileDeferred = async {
            val ctx = preferences.userContext.first()
            val age = preferences.userAge.first()
            val height = preferences.userHeight.first()
            val weight = preferences.userWeight.first()
            val gender = preferences.userGender.first()
            ProfileTuple(ctx, age, height, weight, gender)
        }

        // 3. User Conditions
        val conditionsDeferred = async {
            try {
                val conds = conditionRepository.conditions.first()
                metadataMap["conditions"] = SectionMetadata("conditions", DataSourceStatus.SUCCESS, conds.size)
                conds
            } catch (e: Exception) {
                metadataMap["conditions"] = SectionMetadata("conditions", DataSourceStatus.ERROR, 0, e.message)
                emptyList()
            }
        }

        // 4. Medications
        val medicationsDeferred = async {
            try {
                val medsStr = preferences.medications.first()
                val meds = if (medsStr.isNotBlank()) {
                    // The DataStore JSON is always written with the
                    // com.notel.notel.ui.viewmodel.Medication serializer (id is a UUID
                    // String) — never the Room entity serializer. Decoding it as the
                    // entity type threw on the String->Long id coercion, which surfaced
                    // as a spurious "Medications: Unavailable" with real data behind it.
                    kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
                        .decodeFromString<List<com.notel.notel.ui.viewmodel.Medication>>(medsStr)
                        .filter { !it.isDeleted && it.isPresent }
                        .map { vm ->
                            Medication(
                                uuid = vm.id,
                                name = vm.name,
                                dose = vm.dose,
                                frequency = vm.frequency,
                                startedDate = vm.startDate.ifBlank { null },
                                endedDate = if (vm.isPresent || vm.endDate.isBlank()
                                    || vm.endDate.equals("Present", ignoreCase = true)
                                ) null else vm.endDate,
                                isArchived = false,
                                updatedAt = vm.updatedAt,
                                isDeleted = vm.isDeleted
                            )
                        }
                } else emptyList()
                metadataMap["medications"] = SectionMetadata("medications", DataSourceStatus.SUCCESS, meds.size)
                meds
            } catch (e: Exception) {
                metadataMap["medications"] = SectionMetadata("medications", DataSourceStatus.ERROR, 0, e.message)
                emptyList()
            }
        }

        // 5. Knowledge Documents
        val documentsDeferred = async {
            try {
                val docs = knowledgeDocumentDao.getAllDocuments().first()
                val extractedTexts = docs.mapNotNull { doc ->
                    if (!doc.extractedText.isNullOrBlank()) doc.extractedText
                    else null
                }
                metadataMap["documents"] = SectionMetadata("documents", DataSourceStatus.SUCCESS, extractedTexts.size)
                extractedTexts
            } catch (e: Exception) {
                metadataMap["documents"] = SectionMetadata("documents", DataSourceStatus.ERROR, 0, e.message)
                emptyList()
            }
        }

        // 6. Blood Pressure
        val bpDeferred = async {
            try {
                val allBp = bloodPressureRepository.getAllRecords()
                val filteredBp = if (last30DaysOnly) {
                    allBp.filter { it.timeEpochMs >= cutoff }
                } else allBp
                metadataMap["bloodPressure"] = SectionMetadata("bloodPressure", DataSourceStatus.SUCCESS, filteredBp.size)
                filteredBp
            } catch (e: Exception) {
                metadataMap["bloodPressure"] = SectionMetadata("bloodPressure", DataSourceStatus.ERROR, 0, e.message)
                emptyList()
            }
        }

        // 7. Health Connect metrics
        val hasHcPermissions = healthConnectManager.hasAllPermissions()
        val targetToday = LocalDate.now()
        val minDateStr = targetToday.minusDays((daysToFetch - 1).toLong()).toString()

        val sleepDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["sleep"] = SectionMetadata("sleep", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            val res = withTimeoutOrNull(20_000L) {
                healthConnectCoordinator.getSleepHistory(days = daysToFetch, targetToday = targetToday)
            }
            if (res != null) {
                metadataMap["sleep"] = SectionMetadata("sleep", if (res.isNotEmpty()) DataSourceStatus.SUCCESS else DataSourceStatus.NO_DATA, res.size)
                res
            } else {
                metadataMap["sleep"] = SectionMetadata("sleep", DataSourceStatus.TIMED_OUT, 0, "Query timed out after 20s")
                emptyList()
            }
        }

        val heartRateDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["heartRate"] = SectionMetadata("heartRate", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            // Cache-first: the phone already maintains daily avg-HR history in
            // DataStore (written by LogRepository from Health Connect and by
            // FitbitViewModel from Fitbit), so use it instead of re-reading
            // 180 days of raw samples with a short timeout.
            val cached = readCachedHeartRate(minDateStr)
            if (cached.isNotEmpty()) {
                metadataMap["heartRate"] = SectionMetadata("heartRate", DataSourceStatus.SUCCESS, cached.size, "Cached data")
                return@async cached
            }
            // Fallback: raw Health Connect read, chunked per 30 days with a
            // 30s window per chunk so a cold cache still has a chance (a single
            // 20s window was not enough for a 180-day cold read).
            val (raw, timedOut) = chunkedHcRead(daysToFetch, targetToday) { n, end ->
                healthConnectCoordinator.getHeartRateHistory(days = n, targetToday = end)
            }
            val merged = raw.sortedBy { it.first }
            when {
                merged.isNotEmpty() -> {
                    val msg = if (timedOut) "Partial data: some date ranges timed out" else null
                    metadataMap["heartRate"] = SectionMetadata("heartRate", DataSourceStatus.SUCCESS, merged.size, msg)
                    merged
                }
                timedOut -> {
                    metadataMap["heartRate"] = SectionMetadata("heartRate", DataSourceStatus.TIMED_OUT, 0, "Query timed out")
                    emptyList()
                }
                else -> {
                    metadataMap["heartRate"] = SectionMetadata("heartRate", DataSourceStatus.NO_DATA, 0)
                    emptyList()
                }
            }
        }

        val caloriesDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["calories"] = SectionMetadata("calories", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            val res = withTimeoutOrNull(20_000L) {
                healthConnectCoordinator.getCaloriesHistory(days = daysToFetch, targetToday = targetToday)
            }
            if (res != null && res.isNotEmpty()) {
                metadataMap["calories"] = SectionMetadata("calories", DataSourceStatus.SUCCESS, res.size)
                res
            } else {
                // Fallback: Fitbit API calorie history cached in preferences by FitbitViewModel
                val fitbitCals = readFitbitCachedCalories(minDateStr)
                if (fitbitCals.isNotEmpty()) {
                    metadataMap["calories"] = SectionMetadata("calories", DataSourceStatus.SUCCESS, fitbitCals.size, "Fitbit data")
                    fitbitCals
                } else if (res == null) {
                    metadataMap["calories"] = SectionMetadata("calories", DataSourceStatus.TIMED_OUT, 0, "Query timed out after 20s")
                    emptyList()
                } else {
                    metadataMap["calories"] = SectionMetadata("calories", DataSourceStatus.NO_DATA, 0)
                    emptyList()
                }
            }
        }

        val spikesDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["hrSpikes"] = SectionMetadata("hrSpikes", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            // Cache-first: LogRepository incrementally maintains a 180-day
            // per-day spike cache (historicalHrSpikes); use it directly.
            val cached = readCachedHrSpikes(minDateStr)
            if (cached.isNotEmpty()) {
                metadataMap["hrSpikes"] = SectionMetadata("hrSpikes", DataSourceStatus.SUCCESS, cached.size, "Cached data")
                return@async cached
            }
            // Fallback: raw Health Connect read, chunked per 30 days with a
            // 30s window per chunk so a cold cache still has a chance.
            val (raw, timedOut) = chunkedHcRead(daysToFetch, targetToday) { n, end ->
                healthConnectCoordinator.getHrSpikesHistory(days = n, targetToday = end)
            }
            val merged = raw.distinctBy { it.date }.sortedBy { it.date }
            when {
                merged.isNotEmpty() -> {
                    val msg = if (timedOut) "Partial data: some date ranges timed out" else null
                    metadataMap["hrSpikes"] = SectionMetadata("hrSpikes", DataSourceStatus.SUCCESS, merged.size, msg)
                    merged
                }
                timedOut -> {
                    metadataMap["hrSpikes"] = SectionMetadata("hrSpikes", DataSourceStatus.TIMED_OUT, 0, "Query timed out")
                    emptyList()
                }
                else -> {
                    metadataMap["hrSpikes"] = SectionMetadata("hrSpikes", DataSourceStatus.NO_DATA, 0)
                    emptyList()
                }
            }
        }

        val hrvDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["hrv"] = SectionMetadata("hrv", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            // Cache-first: SyncManager builds per-day "Biometrics" AiInsight
            // entries (up to 180 days) with a JSON payload containing the day's
            // HRV, so reuse those instead of re-reading dense raw samples.
            val cached = readCachedHrv(minDateStr)
            if (cached.isNotEmpty()) {
                metadataMap["hrv"] = SectionMetadata("hrv", DataSourceStatus.SUCCESS, cached.size, "Cached data")
                return@async cached
            }
            // HRV is a dense record type (many readings per night); use the coordinator's
            // cached read and allow a longer timeout for a cold 180-day fetch.
            val res = withTimeoutOrNull(60_000L) {
                try {
                    healthConnectCoordinator.getHeartRateVariability(days = daysToFetch, targetDateStr = targetToday.toString())
                } catch (e: Exception) { null }
            }
            if (res != null && res.isNotEmpty()) {
                metadataMap["hrv"] = SectionMetadata("hrv", DataSourceStatus.SUCCESS, res.size)
                res
            } else {
                // Fallback: Fitbit Web API daily HRV (RMSSD) time series
                val fitbitHrv = withTimeoutOrNull(20_000L) { fetchHrvFromFitbit(minDateStr, targetToday.toString()) }
                if (!fitbitHrv.isNullOrEmpty()) {
                    metadataMap["hrv"] = SectionMetadata("hrv", DataSourceStatus.SUCCESS, fitbitHrv.size, "Fitbit data")
                    fitbitHrv
                } else if (res == null) {
                    metadataMap["hrv"] = SectionMetadata("hrv", DataSourceStatus.TIMED_OUT, 0, "Query timed out after 60s")
                    emptyList()
                } else {
                    metadataMap["hrv"] = SectionMetadata("hrv", DataSourceStatus.NO_DATA, 0)
                    emptyList()
                }
            }
        }

        val deepSleepDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["deepSleep"] = SectionMetadata("deepSleep", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            val res = withTimeoutOrNull(20_000L) {
                try {
                    healthConnectManager.readHistoricalSleepWithDeep(days = daysToFetch)
                } catch (e: Exception) { null }
            }
            if (res != null) {
                val mapped = res.filter { it.deepMinutes > 0 }.map { it.date to it.deepMinutes }
                metadataMap["deepSleep"] = SectionMetadata("deepSleep", if (mapped.isNotEmpty()) DataSourceStatus.SUCCESS else DataSourceStatus.NO_DATA, mapped.size)
                mapped
            } else {
                metadataMap["deepSleep"] = SectionMetadata("deepSleep", DataSourceStatus.TIMED_OUT, 0, "Query timed out after 20s")
                emptyList()
            }
        }

        // Await all
        val entries = logsDeferred.await()
        val profile = profileDeferred.await()
        val conds = conditionsDeferred.await()
        val meds = medicationsDeferred.await()
        val docs = documentsDeferred.await()
        val bpList = bpDeferred.await()
        val sleepList = sleepDeferred.await()
        val hrList = heartRateDeferred.await()
        val calList = caloriesDeferred.await()
        val spikesList = spikesDeferred.await()
        val hrvList = hrvDeferred.await()
        val deepSleepList = deepSleepDeferred.await()

        val catMap = allCategories.associate { it.id to it.name }

        ClinicalReportData(
            range = range,
            generationTimestamp = now,
            logEntries = entries,
            categoriesMap = catMap,
            userContext = profile.userContext,
            userAge = profile.age,
            userHeight = profile.height,
            userWeight = profile.weight,
            userGender = profile.gender,
            conditions = conds,
            medications = meds,
            knowledgeDocuments = docs,
            heartRateSeries = hrList,
            sleepSeries = sleepList,
            deepSleepSeries = deepSleepList,
            caloriesSeries = calList,
            hrvSeries = hrvList,
            heartRateSpikes = spikesList,
            bloodPressureSeries = bpList,
            bodyLoadHistory = "",
            sectionMetadata = metadataMap.toMap()
        )
    }

    /**
     * Cache-first HR avg: preferences.historicalHeartRate (BiomarkerPoint list
     * written by LogRepository / FitbitViewModel), backfilled with avgHr from
     * per-day "Biometrics" AiInsight entries for dates the list is missing.
     */
    private suspend fun readCachedHeartRate(minDate: String): List<Pair<String, Int>> {
        return try {
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            val merged = mutableMapOf<String, Int>()
            val raw = preferences.historicalHeartRate.first()
            if (raw.isNotBlank()) {
                json.decodeFromString<List<BiomarkerPoint>>(raw)
                    .filter { it.date >= minDate && it.value > 0 }
                    .forEach { merged[it.date] = it.value }
            }
            readBiometricsEntries(minDate).forEach { (date, payload) ->
                if (!merged.containsKey(date)) {
                    val avgHr = payload["avgHr"]?.jsonPrimitive?.intOrNull ?: 0
                    if (avgHr > 0) merged[date] = avgHr
                }
            }
            merged.toList().sortedBy { it.first }
        } catch (e: Exception) { emptyList() }
    }

    /**
     * Cache-first HR spikes: preferences.historicalHrSpikes, the 180-day
     * per-day spike cache incrementally maintained by LogRepository.
     */
    private suspend fun readCachedHrSpikes(minDate: String): List<com.notel.notel.data.healthconnect.DailyHeartRateSummary> {
        return try {
            val raw = preferences.historicalHrSpikes.first()
            if (raw.isBlank()) return emptyList()
            kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
                .decodeFromString<List<com.notel.notel.data.healthconnect.DailyHeartRateSummary>>(raw)
                .filter { it.date >= minDate }
                .sortedBy { it.date }
        } catch (e: Exception) { emptyList() }
    }

    /**
     * Cache-first HRV: per-day "Biometrics" AiInsight entries (v6), whose text
     * payload JSON carries the day's HRV ({"sleepMins":N,...,"hrv":N,...}).
     */
    private suspend fun readCachedHrv(minDate: String): List<Pair<String, Double>> {
        return try {
            readBiometricsEntries(minDate).mapNotNull { (date, payload) ->
                val hrv = payload["hrv"]?.jsonPrimitive?.doubleOrNull ?: 0.0
                if (hrv > 0.0) date to hrv else null
            }
        } catch (e: Exception) { emptyList() }
    }

    /**
     * Reads per-day "Biometrics" AiInsight entries (v6) in the requested date
     * range, returning (date, parsed text-payload JSON) pairs.
     */
    private suspend fun readBiometricsEntries(minDate: String): List<Pair<String, kotlinx.serialization.json.JsonObject>> {
        return try {
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            val raw = preferences.aiInsights.first()
            if (raw.isBlank()) return emptyList()
            json.decodeFromString<List<com.notel.notel.data.local.entity.AiInsight>>(raw)
                .filter { it.type == "Biometrics" && it.id.endsWith("_v6") }
                .mapNotNull { insight ->
                    val date = insight.id.removePrefix("biometrics_").removeSuffix("_v6")
                    if (date < minDate) return@mapNotNull null
                    val obj = try {
                        json.parseToJsonElement(insight.text).jsonObject
                    } catch (e: Exception) { null } ?: return@mapNotNull null
                    date to obj
                }
                .sortedBy { it.first }
        } catch (e: Exception) { emptyList() }
    }

    /**
     * Runs a Health Connect history read in per-[chunkDays] chunks, each with
     * its own [perChunkTimeoutMs] window, so a cold multi-month read still
     * makes progress instead of dying on one short timeout. Returns the merged
     * rows plus whether any chunk timed out.
     */
    private suspend fun <T> chunkedHcRead(
        days: Int,
        targetToday: LocalDate,
        chunkDays: Int = 30,
        perChunkTimeoutMs: Long = 30_000L,
        read: suspend (days: Int, end: LocalDate) -> List<T>
    ): Pair<List<T>, Boolean> {
        val merged = mutableListOf<T>()
        var anyTimedOut = false
        var remaining = days
        var end = targetToday
        while (remaining > 0) {
            val n = minOf(chunkDays, remaining)
            val chunkEnd = end
            val res = withTimeoutOrNull(perChunkTimeoutMs) {
                try { read(n, chunkEnd) } catch (e: Exception) { null }
            }
            if (res == null) anyTimedOut = true else merged.addAll(res)
            remaining -= n
            end = end.minusDays(n.toLong())
        }
        return merged to anyTimedOut
    }

    /**
     * Fallback: Fitbit API calorie history cached in preferences by FitbitViewModel
     * (6-month time series from the Fitbit Web API). Used when Health Connect
     * has no calorie records.
     */
    private suspend fun readFitbitCachedCalories(minDate: String): List<Pair<String, Int>> {
        return try {
            val raw = preferences.historicalCalories.first()
            if (raw.isBlank()) return emptyList()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            json.decodeFromString<List<BiomarkerPoint>>(raw)
                .filter { it.date >= minDate && it.value > 0 }
                .map { it.date to it.value }
                .sortedBy { it.first }
        } catch (e: Exception) { emptyList() }
    }

    /**
     * Fallback: Fitbit Web API daily HRV (RMSSD) time series. Used when Health
     * Connect has no HRV records (e.g. wearables that don't sync HRV to HC).
     */
    private suspend fun fetchHrvFromFitbit(startDate: String, endDate: String): List<Pair<String, Double>> {
        return try {
            val token = preferences.fitbitToken.first()
            if (token.isBlank()) return emptyList()
            val client = okhttp3.OkHttpClient()
            val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
            val request = okhttp3.Request.Builder()
                .url("https://api.fitbit.com/1/user/-/hrv/date/$startDate/$endDate.json")
                .header("Authorization", "Bearer $token")
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return emptyList()
                val body = response.body?.string() ?: return emptyList()
                val root = json.parseToJsonElement(body).jsonObject
                root["hrv"]?.jsonArray?.mapNotNull { el ->
                    val obj = el.jsonObject
                    val date = obj["dateTime"]?.jsonPrimitive?.content ?: return@mapNotNull null
                    val rmssd = obj["value"]?.jsonObject
                        ?.get("dailyRmssd")?.jsonPrimitive?.doubleOrNull
                        ?: return@mapNotNull null
                    date to rmssd
                } ?: emptyList()
            }
        } catch (e: Exception) { emptyList() }
    }
}

private data class ProfileTuple(
    val userContext: String,
    val age: Int,
    val height: Float,
    val weight: Float,
    val gender: String
)
