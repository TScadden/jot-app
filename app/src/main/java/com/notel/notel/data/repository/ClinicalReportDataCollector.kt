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
                    kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
                        .decodeFromString<List<Medication>>(medsStr)
                        .filter { !it.isDeleted && !it.isArchived }
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
            val res = withTimeoutOrNull(20_000L) {
                healthConnectCoordinator.getHeartRateHistory(days = daysToFetch, targetToday = targetToday)
            }
            if (res != null) {
                metadataMap["heartRate"] = SectionMetadata("heartRate", if (res.isNotEmpty()) DataSourceStatus.SUCCESS else DataSourceStatus.NO_DATA, res.size)
                res
            } else {
                metadataMap["heartRate"] = SectionMetadata("heartRate", DataSourceStatus.TIMED_OUT, 0, "Query timed out after 20s")
                emptyList()
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
            val res = withTimeoutOrNull(20_000L) {
                healthConnectCoordinator.getHrSpikesHistory(days = daysToFetch, targetToday = targetToday)
            }
            if (res != null) {
                metadataMap["hrSpikes"] = SectionMetadata("hrSpikes", if (res.isNotEmpty()) DataSourceStatus.SUCCESS else DataSourceStatus.NO_DATA, res.size)
                res
            } else {
                metadataMap["hrSpikes"] = SectionMetadata("hrSpikes", DataSourceStatus.TIMED_OUT, 0, "Query timed out after 20s")
                emptyList()
            }
        }

        val hrvDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["hrv"] = SectionMetadata("hrv", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
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
