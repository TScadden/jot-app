package com.notel.notel.data.repository

import com.notel.notel.data.healthconnect.HealthConnectCoordinator
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.KnowledgeDocumentDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.model.*
import com.notel.notel.data.preferences.NotelPreferences
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import javax.inject.Inject
import javax.inject.Singleton

private const val DAY_MS = 24 * 60 * 60 * 1000L

/**
 * Bounds live Health Connect reads (Phase 1, WS-B). Beyond this, per-chunk
 * timeouts make collection take many minutes, and the device never holds
 * more than its finite retention anyway. Stored-cache reads (DataStore lists,
 * Biometrics AiInsight entries) are NOT capped — they are cheap date-string
 * filters over everything ever stored. Every clamp is disclosed in the
 * section metadata message.
 */
private const val MAX_LIVE_HC_DAYS = 730

/** Result of one bounded Health Connect read. */
private data class HcReadResult<T>(
    val rows: List<T>,
    val timedOut: Boolean,
    val failed: Boolean
)

@Singleton
class ClinicalReportDataCollector @Inject constructor(
    private val logEntryDao: LogEntryDao,
    private val knowledgeDocumentDao: KnowledgeDocumentDao,
    private val preferences: NotelPreferences,
    private val conditionRepository: ConditionRepository,
    private val bloodPressureRepository: BloodPressureRepository,
    private val healthConnectCoordinator: HealthConnectCoordinator,
    private val healthConnectManager: HealthConnectManager,
    private val syncopeEventDao: com.notel.notel.data.local.dao.SyncopeEventDao,
    private val migraineAttackDao: com.notel.notel.data.local.dao.MigraineAttackDao
) {

    /**
     * Legacy overload. Preserves the old semantics exactly: entries are NOT
     * filtered by focus (Custom focus over every category = no filtering).
     */
    @Deprecated("Use collectReportData(allCategories, range, focus, customCategoryIds)")
    suspend fun collectReportData(
        allCategories: List<Category>,
        last30DaysOnly: Boolean
    ): ClinicalReportData = collectReportData(
        allCategories = allCategories,
        range = if (last30DaysOnly) ReportRange.Last30Days else ReportRange.AllTime,
        focus = ReportFocus.Custom(""),
        customCategoryIds = allCategories.map { it.id }.toSet()
    )

    suspend fun collectReportData(
        allCategories: List<Category>,
        range: ReportRange,
        focus: ReportFocus,
        customCategoryIds: Set<Int> = emptySet()
    ): ClinicalReportData = coroutineScope {
        val now = System.currentTimeMillis()
        val clinicalRange = range.toClinicalReportRange(now)
        val start = clinicalRange.startEpochMs
        val zone = try { ZoneId.of(clinicalRange.timezoneId) } catch (_: Exception) { ZoneId.systemDefault() }
        val targetToday = LocalDate.now(zone)

        // WS-B: entries are range-bounded with NO entry-count cap. AllTime
        // means startEpochMs = 0 — every stored record, however old.
        val spanDays = ((now - start).coerceAtLeast(0L) / DAY_MS).toInt() + 1
        val liveHcDays = spanDays.coerceAtMost(MAX_LIVE_HC_DAYS)
        val hcClamped = spanDays > MAX_LIVE_HC_DAYS
        // WS-B: minDateStr follows the range start, uncapped — cache reads are
        // cheap date-string filters. Health Connect retention is finite, so
        // the live reads above stay bounded; that is disclosed per metric.
        val minDateStr = LocalDate.ofInstant(
            Instant.ofEpochMilli(start.coerceAtLeast(0L)), zone
        ).toString()
        val liveStartStr = targetToday.minusDays((liveHcDays - 1).toLong()).toString()

        // WS-F (the key fix): the collector actually FILTERS log entries by
        // the focus's categories. Previously allCategories was ignored for
        // entries, so Health/Training/Custom only changed labels.
        val focusIds = resolveFocusCategoryIds(allCategories, focus, customCategoryIds)
        val focusNote =
            "Focus '${focus.key}': ${focusIds.size} of ${allCategories.size} categories included"

        val clampNote = if (hcClamped)
            "Live device read covers $liveStartStr..today (most recent $MAX_LIVE_HC_DAYS days; Health Connect retention is finite); stored caches queried from $minDateStr."
        else null

        val metadataMap = java.util.concurrent.ConcurrentHashMap<String, SectionMetadata>()

        // 1. Logs — range-bounded, uncapped, focus-filtered.
        val logsDeferred = async {
            try {
                val entries = logEntryDao.getRecentEntriesInRange(start, now)
                    .filter { it.categoryId in focusIds }
                metadataMap["logs"] = SectionMetadata("logs", DataSourceStatus.SUCCESS, entries.size, focusNote)
                entries
            } catch (e: Exception) {
                metadataMap["logs"] = SectionMetadata("logs", DataSourceStatus.ERROR, 0, e.javaClass.simpleName)
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
                metadataMap["conditions"] = SectionMetadata("conditions", DataSourceStatus.ERROR, 0, e.javaClass.simpleName)
                emptyList()
            }
        }

        // 4. Medications
        val medicationsDeferred = async {
            try {
                val meds = readMedications()
                metadataMap["medications"] = SectionMetadata("medications", DataSourceStatus.SUCCESS, meds.size)
                meds
            } catch (e: Exception) {
                metadataMap["medications"] = SectionMetadata("medications", DataSourceStatus.ERROR, 0, e.javaClass.simpleName)
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
                metadataMap["documents"] = SectionMetadata("documents", DataSourceStatus.ERROR, 0, e.javaClass.simpleName)
                emptyList()
            }
        }

        // 6. Blood Pressure — uncapped as before; filtered to the range start
        // for bounded ranges, all records for AllTime.
        val bpDeferred = async {
            try {
                val allBp = bloodPressureRepository.getAllRecords()
                val filteredBp = if (range is ReportRange.AllTime) allBp
                else allBp.filter { it.timeEpochMs >= start }
                metadataMap["bloodPressure"] = SectionMetadata("bloodPressure", DataSourceStatus.SUCCESS, filteredBp.size)
                filteredBp
            } catch (e: Exception) {
                metadataMap["bloodPressure"] = SectionMetadata("bloodPressure", DataSourceStatus.ERROR, 0, e.javaClass.simpleName)
                emptyList()
            }
        }

        // 7. Health Connect metrics
        val hasHcPermissions = healthConnectManager.hasAllPermissions()

        val sleepDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["sleep"] = SectionMetadata("sleep", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            // One continuous string: per-day "Biometrics" v6 insights carry
            // sleepMins, so older days Health Connect has aged out (~14-day
            // retention) still render. Live HC read overrides recent days with
            // the freshest data. Zeros are never real — filtered everywhere.
            val cached = readCachedSleep(minDateStr)
            val res = withTimeoutOrNull(20_000L) {
                healthConnectCoordinator.getSleepHistory(days = liveHcDays, targetToday = targetToday)
            }
            val merged = mutableMapOf<String, Int>()
            cached.forEach { (date, mins) -> merged[date] = mins }
            if (res != null) {
                res.forEach { (date, mins) -> if (mins > 0) merged[date] = mins }
                metadataMap["sleep"] = SectionMetadata("sleep", if (merged.isNotEmpty()) DataSourceStatus.SUCCESS else DataSourceStatus.NO_DATA, merged.size, "Cached data + live Health Connect")
            } else {
                metadataMap["sleep"] = SectionMetadata("sleep", if (merged.isNotEmpty()) DataSourceStatus.SUCCESS else DataSourceStatus.TIMED_OUT, merged.size, if (merged.isNotEmpty()) "Cached data (live read timed out)" else "Query timed out after 20s")
            }
            merged.toList().sortedBy { it.first }
        }

        val heartRateDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["heartRate"] = SectionMetadata("heartRate", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            // Cache-first: the phone already maintains daily avg-HR history in
            // DataStore (written by LogRepository from Health Connect and by
            // FitbitViewModel from Fitbit), so use it instead of re-reading
            // raw samples with a short timeout. The cache read is uncapped —
            // minDateStr follows the range start.
            val cached = readCachedHeartRate(minDateStr)
            if (cached.isNotEmpty()) {
                metadataMap["heartRate"] = SectionMetadata(
                    "heartRate", DataSourceStatus.SUCCESS, cached.size,
                    combineNotes("Cached data", clampNote)
                )
                return@async cached
            }
            // Fallback: raw Health Connect read, chunked per 30 days with a
            // 30s window per chunk so a cold cache still has a chance.
            val res = boundedHcRead(liveHcDays, targetToday) { n, end ->
                healthConnectCoordinator.getHeartRateHistory(days = n, targetToday = end)
            }
            metadataMap["heartRate"] = hcMetadata("heartRate", res, clampNote)
            res.rows.sortedBy { it.first }
        }

        val caloriesDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["calories"] = SectionMetadata("calories", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            val res = boundedHcRead(liveHcDays, targetToday) { n, end ->
                healthConnectCoordinator.getCaloriesHistory(days = n, targetToday = end)
            }
            if (res.rows.isNotEmpty()) {
                metadataMap["calories"] = hcMetadata("calories", res, clampNote)
                res.rows
            } else {
                // Fallback: Fitbit API calorie history cached in preferences by FitbitViewModel
                val fitbitCals = readFitbitCachedCalories(minDateStr)
                if (fitbitCals.isNotEmpty()) {
                    metadataMap["calories"] = SectionMetadata(
                        "calories", DataSourceStatus.SUCCESS, fitbitCals.size,
                        combineNotes("Fitbit data", clampNote)
                    )
                    fitbitCals
                } else {
                    metadataMap["calories"] = hcMetadata("calories", res, clampNote)
                    emptyList()
                }
            }
        }

        val spikesDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["hrSpikes"] = SectionMetadata("hrSpikes", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            // Cache-first: LogRepository incrementally maintains a per-day
            // spike cache (historicalHrSpikes); use it directly. Uncapped —
            // minDateStr follows the range start.
            val cached = readCachedHrSpikes(minDateStr)
            if (cached.isNotEmpty()) {
                metadataMap["hrSpikes"] = SectionMetadata(
                    "hrSpikes", DataSourceStatus.SUCCESS, cached.size,
                    combineNotes("Cached data", clampNote)
                )
                return@async cached
            }
            // Middle layer: per-day "Biometrics" AiInsight entries (v6) carry
            // the day's spike count in their JSON payload — the same source
            // the web dashboard's HR-spike graph reads. Much cheaper than the
            // raw Health Connect chunked read below.
            val insightSpikes = readBiometricsSpikes(minDateStr)
            if (insightSpikes.isNotEmpty()) {
                metadataMap["hrSpikes"] = SectionMetadata("hrSpikes", DataSourceStatus.SUCCESS, insightSpikes.size, "Biometrics insights")
                return@async insightSpikes
            }
            // Fallback: raw Health Connect read, chunked per 30 days with a
            // 60s window per chunk. Spike detection reads raw paginated HR
            // samples — the heaviest Health Connect query in this pipeline —
            // so it gets double the headroom of the other sections. (A cold
            // cache + 30s chunks timed out every chunk on a background run.)
            val (raw, timedOut) = chunkedHcRead(liveHcDays, targetToday, perChunkTimeoutMs = 60_000L) { n, end ->
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
            // entries with a JSON payload containing the day's HRV. Uncapped.
            val cached = readCachedHrv(minDateStr)
            if (cached.isNotEmpty()) {
                metadataMap["hrv"] = SectionMetadata(
                    "hrv", DataSourceStatus.SUCCESS, cached.size,
                    combineNotes("Cached data", clampNote)
                )
                return@async cached
            }
            // HRV is a dense record type (many readings per night); bound the
            // live read and allow a longer timeout for a cold fetch.
            val hrvDays = liveHcDays.coerceAtMost(365)
            val hrvClampNote = combineNotes(
                if (hrvDays < liveHcDays) "HRV live read limited to the most recent $hrvDays days (dense record type)." else null,
                clampNote
            )
            val res = withTimeoutOrNull(60_000L) {
                try {
                    val rows = healthConnectCoordinator.getHeartRateVariability(
                        days = hrvDays, targetDateStr = targetToday.toString()
                    )
                    HcReadResult(rows, timedOut = false, failed = false)
                } catch (e: Exception) { HcReadResult(emptyList<Pair<String, Double>>(), timedOut = false, failed = true) }
            } ?: HcReadResult(emptyList<Pair<String, Double>>(), timedOut = true, failed = false)
            // The Fitbit Web API was retired (Oct 30, 2026), so there is no
            // live Fitbit HRV fallback anymore. Report the honest state instead.
            metadataMap["hrv"] = hcMetadata("hrv", res, hrvClampNote)
            res.rows
        }

        val deepSleepDeferred = async {
            if (!hasHcPermissions) {
                metadataMap["deepSleep"] = SectionMetadata("deepSleep", DataSourceStatus.PERMISSION_DENIED, 0, "Health Connect permissions missing")
                return@async emptyList()
            }
            val deepDays = liveHcDays.coerceAtMost(365)
            val deepClampNote = combineNotes(
                if (deepDays < liveHcDays) "Deep-sleep live read limited to the most recent $deepDays days." else null,
                clampNote
            )
            val res = withTimeoutOrNull(20_000L) {
                try {
                    val rows = healthConnectManager.readHistoricalSleepWithDeep(days = deepDays)
                    HcReadResult(rows, timedOut = false, failed = false)
                } catch (e: Exception) {
                    HcReadResult(
                        emptyList<com.notel.notel.data.healthconnect.DailySleepSummary>(),
                        timedOut = false, failed = true
                    )
                }
            } ?: HcReadResult(
                emptyList<com.notel.notel.data.healthconnect.DailySleepSummary>(),
                timedOut = true, failed = false
            )
            val mapped = res.rows.filter { it.deepMinutes > 0 }.map { it.date to it.deepMinutes }
            val base = hcMetadata("deepSleep", HcReadResult(mapped, res.timedOut, res.failed), deepClampNote)
            metadataMap["deepSleep"] = base
            mapped
        }

        // 8. Syncope + migraine events (Tabs Lab): safety-relevant doctor history,
        // read straight from the local Lab tables with the same cutoff.
        val syncopeDeferred = async {
            try {
                val events = syncopeEventDao.getEventsSince(start)
                metadataMap["syncopeEvents"] = SectionMetadata("syncopeEvents", DataSourceStatus.SUCCESS, events.size)
                events
            } catch (e: Exception) {
                metadataMap["syncopeEvents"] = SectionMetadata("syncopeEvents", DataSourceStatus.ERROR, 0, e.javaClass.simpleName)
                emptyList()
            }
        }

        val migraineDeferred = async {
            try {
                val attacks = migraineAttackDao.getAttacksSince(start)
                metadataMap["migraineAttacks"] = SectionMetadata("migraineAttacks", DataSourceStatus.SUCCESS, attacks.size)
                attacks
            } catch (e: Exception) {
                metadataMap["migraineAttacks"] = SectionMetadata("migraineAttacks", DataSourceStatus.ERROR, 0, e.javaClass.simpleName)
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
        val syncopeList = syncopeDeferred.await()
        val migraineList = migraineDeferred.await()

        // WS-B: disclose per-metric actual coverage (what dates actually came
        // back — missing data is not zero). Counts and date spans only.
        appendCoverage(metadataMap, "sleep", sleepList.map { it.first })
        appendCoverage(metadataMap, "heartRate", hrList.map { it.first })
        appendCoverage(metadataMap, "calories", calList.map { it.first })
        appendCoverage(metadataMap, "hrv", hrvList.map { it.first })
        appendCoverage(metadataMap, "deepSleep", deepSleepList.map { it.first })
        appendCoverage(metadataMap, "hrSpikes", spikesList.map { it.date })
        appendCoverage(
            metadataMap, "bloodPressure",
            bpList.map {
                LocalDate.ofInstant(Instant.ofEpochMilli(it.timeEpochMs), zone).toString()
            }
        )

        val catMap = allCategories.associate { it.id to it.name }

        ClinicalReportData(
            range = clinicalRange,
            generationTimestamp = now,
            focusKey = focus.key,
            focusText = (focus as? ReportFocus.Custom)?.focusText.orEmpty(),
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
            syncopeEvents = syncopeList,
            migraineAttacks = migraineList,
            sectionMetadata = metadataMap.toMap()
        )
    }

    /**
     * Reads the stored medication list from DataStore and maps it to Room
     * entities (Phase 2: extracted so the preview path can reuse it).
     *
     * The DataStore JSON is always written with the
     * com.notel.notel.ui.viewmodel.Medication serializer (id is a UUID
     * String) — never the Room entity serializer. Decoding it as the
     * entity type threw on the String->Long id coercion, which surfaced
     * as a spurious "Medications: Unavailable" with real data behind it.
     */
    private suspend fun readMedications(): List<Medication> {
        val medsStr = preferences.medications.first()
        if (medsStr.isBlank()) return emptyList()
        return kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
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
    }

    /**
     * Lightweight preview snapshot (Phase 2, WS-D).
     *
     * The full collection path does live Health Connect reads that can take
     * 30s+; the preview must stay fast and deterministic. This path reads
     * ONLY cheap local sources: Room logs (range-bounded, focus-filtered —
     * same filter as the export) plus the on-device metric caches the export
     * itself prefers (per-day Biometrics entries, HR/HR-spike/calorie
     * DataStore caches). No live Health Connect reads, no network.
     *
     * Consistency rule: the preview aggregates with the SAME pure functions
     * (ReportCharts.kt) as the PDF, from the same cache-first series the
     * export uses first. When the export's cache is cold it falls back to
     * live reads and may cover additional days — that divergence is
     * disclosed in the section metadata, never hidden.
     */
    suspend fun collectPreviewSnapshot(
        allCategories: List<Category>,
        range: ReportRange,
        focus: ReportFocus,
        customCategoryIds: Set<Int> = emptySet()
    ): ClinicalReportData {
        val now = System.currentTimeMillis()
        val clinicalRange = range.toClinicalReportRange(now)
        val start = clinicalRange.startEpochMs
        val zone = try { ZoneId.of(clinicalRange.timezoneId) } catch (_: Exception) { ZoneId.systemDefault() }
        val minDateStr = LocalDate.ofInstant(
            Instant.ofEpochMilli(start.coerceAtLeast(0L)), zone
        ).toString()

        val focusIds = resolveFocusCategoryIds(allCategories, focus, customCategoryIds)
        val metadata = mutableMapOf<String, SectionMetadata>()
        metadata["previewMode"] = SectionMetadata(
            "previewMode", DataSourceStatus.SUCCESS, 0,
            "Preview snapshot: local logs and cached metrics only — no live Health Connect reads. " +
                "The export may cover additional days when its cache is cold and it falls back to live reads."
        )

        val entries = try {
            val e = logEntryDao.getRecentEntriesInRange(start, now).filter { it.categoryId in focusIds }
            metadata["logs"] = SectionMetadata("logs", DataSourceStatus.SUCCESS, e.size,
                "Focus '${focus.key}': ${focusIds.size} of ${allCategories.size} categories included (preview)")
            e
        } catch (e: Exception) {
            metadata["logs"] = SectionMetadata("logs", DataSourceStatus.ERROR, 0, e.javaClass.simpleName)
            emptyList()
        }

        val profile = ProfileTuple(
            preferences.userContext.first(),
            preferences.userAge.first(),
            preferences.userHeight.first(),
            preferences.userWeight.first(),
            preferences.userGender.first()
        )
        val conds = try {
            conditionRepository.conditions.first()
        } catch (_: Exception) { emptyList() }
        metadata["conditions"] = SectionMetadata("conditions", DataSourceStatus.SUCCESS, conds.size)
        val meds = try { readMedications() } catch (_: Exception) { emptyList() }
        metadata["medications"] = SectionMetadata("medications", DataSourceStatus.SUCCESS, meds.size)
        val docs = try {
            knowledgeDocumentDao.getAllDocuments().first().mapNotNull { it.extractedText?.ifBlank { null } }
        } catch (_: Exception) { emptyList<String>() }
        metadata["documents"] = SectionMetadata("documents", DataSourceStatus.SUCCESS, docs.size)
        val bp = try {
            val all = bloodPressureRepository.getAllRecords()
            if (range is ReportRange.AllTime) all else all.filter { it.timeEpochMs >= start }
        } catch (_: Exception) { emptyList() }
        metadata["bloodPressure"] = SectionMetadata("bloodPressure", DataSourceStatus.SUCCESS, bp.size)

        // Cached metrics only — the same caches the export prefers.
        val sleep = readCachedSleep(minDateStr)
        metadata["sleep"] = SectionMetadata("sleep", if (sleep.isEmpty()) DataSourceStatus.NO_DATA else DataSourceStatus.SUCCESS,
            sleep.size, "Preview: cached data only")
        val hr = readCachedHeartRate(minDateStr)
        metadata["heartRate"] = SectionMetadata("heartRate", if (hr.isEmpty()) DataSourceStatus.NO_DATA else DataSourceStatus.SUCCESS,
            hr.size, "Preview: cached data only")
        val hrv = readCachedHrv(minDateStr)
        metadata["hrv"] = SectionMetadata("hrv", if (hrv.isEmpty()) DataSourceStatus.NO_DATA else DataSourceStatus.SUCCESS,
            hrv.size, "Preview: cached data only")
        val spikes = readCachedHrSpikes(minDateStr)
        metadata["hrSpikes"] = SectionMetadata("hrSpikes", if (spikes.isEmpty()) DataSourceStatus.NO_DATA else DataSourceStatus.SUCCESS,
            spikes.size, "Preview: cached data only")
        val calories = readCachedCalories(minDateStr)
        metadata["calories"] = SectionMetadata("calories", if (calories.isEmpty()) DataSourceStatus.NO_DATA else DataSourceStatus.SUCCESS,
            calories.size, "Preview: cached data only")
        val deepSleep = readCachedDeepSleep(minDateStr)
        metadata["deepSleep"] = SectionMetadata("deepSleep", if (deepSleep.isEmpty()) DataSourceStatus.NO_DATA else DataSourceStatus.SUCCESS,
            deepSleep.size, "Preview: cached data only")

        val catMap = allCategories.associate { it.id to it.name }
        return ClinicalReportData(
            range = clinicalRange,
            generationTimestamp = now,
            focusKey = focus.key,
            focusText = (focus as? ReportFocus.Custom)?.focusText.orEmpty(),
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
            heartRateSeries = hr,
            sleepSeries = sleep,
            deepSleepSeries = deepSleep,
            caloriesSeries = calories,
            hrvSeries = hrv,
            heartRateSpikes = spikes,
            bloodPressureSeries = bp,
            bodyLoadHistory = "",
            sectionMetadata = metadata
        )
    }

    /**
     * Cache-first sleep minutes: per-day "Biometrics" AiInsight entries (v6)
     * carry sleepMins in their JSON payload.
     */
    private suspend fun readCachedSleep(minDate: String): List<Pair<String, Int>> {
        return try {
            readBiometricsEntries(minDate).mapNotNull { (date, payload) ->
                val mins = payload["sleepMins"]?.jsonPrimitive?.intOrNull ?: 0
                if (mins > 0) date to mins else null
            }
        } catch (e: Exception) { emptyList() }
    }

    /** Cache-first deep-sleep minutes from the same Biometrics entries. */
    private suspend fun readCachedDeepSleep(minDate: String): List<Pair<String, Int>> {
        return try {
            readBiometricsEntries(minDate).mapNotNull { (date, payload) ->
                val mins = payload["deepSleepMins"]?.jsonPrimitive?.intOrNull ?: 0
                if (mins > 0) date to mins else null
            }
        } catch (e: Exception) { emptyList() }
    }

    /**
     * Cache-first calories: per-day "Biometrics" AiInsight entries first,
     * then the Fitbit Web API calorie cache (retired API, but the stored
     * cache is still honest history) for dates the Biometrics entries miss.
     */
    private suspend fun readCachedCalories(minDate: String): List<Pair<String, Int>> {
        return try {
            val merged = mutableMapOf<String, Int>()
            readBiometricsEntries(minDate).forEach { (date, payload) ->
                val cals = payload["calories"]?.jsonPrimitive?.intOrNull ?: 0
                if (cals > 0) merged[date] = cals
            }
            readFitbitCachedCalories(minDate).forEach { (date, cals) ->
                if (!merged.containsKey(date)) merged[date] = cals
            }
            merged.toList().sortedBy { it.first }
        } catch (e: Exception) { emptyList() }
    }
    /**
     * Runs a Health Connect history read in per-[chunkDays] chunks for large
     * day counts (each chunk gets its own timeout), or as a single bounded
     * call for small ones. Never throws: failures surface as [HcReadResult].
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

    private suspend fun <T> boundedHcRead(
        days: Int,
        targetToday: LocalDate,
        chunkDays: Int = 30,
        perChunkTimeoutMs: Long = 30_000L,
        read: suspend (days: Int, end: LocalDate) -> List<T>
    ): HcReadResult<T> {
        if (days <= 90) {
            val res = withTimeoutOrNull(20_000L) {
                try { read(days, targetToday) } catch (e: Exception) { null }
            }
            return when {
                res == null -> HcReadResult(emptyList(), timedOut = true, failed = false)
                else -> HcReadResult(res, timedOut = false, failed = false)
            }
        }
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
            // A null here means the chunk timed out or threw; either way its
            // dates are missing, so it counts as partial (timed out).
            if (res == null) anyTimedOut = true else merged.addAll(res)
            remaining -= n
            end = end.minusDays(n.toLong())
        }
        return HcReadResult(merged, timedOut = anyTimedOut, failed = false)
    }

    /** Metadata for one Health Connect section from a bounded read result. */
    private fun <T> hcMetadata(
        key: String,
        res: HcReadResult<T>,
        clampNote: String?
    ): SectionMetadata {
        val status = when {
            res.failed -> DataSourceStatus.ERROR
            res.rows.isNotEmpty() -> DataSourceStatus.SUCCESS
            res.timedOut -> DataSourceStatus.TIMED_OUT
            else -> DataSourceStatus.NO_DATA
        }
        val timeoutNote = if (res.timedOut && res.rows.isNotEmpty())
            "Partial data: some date ranges timed out." else null
        val timeoutOnly = if (res.timedOut && res.rows.isEmpty())
            "Query timed out." else null
        return SectionMetadata(
            key, status, res.rows.size,
            combineNotes(clampNote, timeoutNote, timeoutOnly)
        )
    }

    private fun combineNotes(vararg notes: String?): String? {
        val parts = notes.filterNotNull().filter { it.isNotBlank() }
        return if (parts.isEmpty()) null else parts.joinToString(" ")
    }

    /**
     * Appends the actual covered date span to a section's metadata message
     * (WS-B coverage disclosure). Counts and ISO dates only — no health
     * values, no PII.
     */
    private fun appendCoverage(
        metadataMap: java.util.concurrent.ConcurrentHashMap<String, SectionMetadata>,
        key: String,
        dates: List<String>
    ) {
        if (dates.isEmpty()) return
        val meta = metadataMap[key] ?: return
        if (meta.status != DataSourceStatus.SUCCESS) return
        val span = "Covers ${dates.min()}..${dates.max()}."
        val msg = combineNotes(meta.message, span)
        metadataMap[key] = meta.copy(message = msg)
    }

    /**
     * Cache-first HR avg: preferences.historicalHeartRate (BiomarkerPoint list
     * written by LogRepository / FitbitViewModel), backfilled with avgHr from
     * per-day "Biometrics" AiInsight entries for dates the list is missing.
     * The metric is the daytime average (awakeAvg, 7am-10pm) in both places —
     * founder's choice; v6 entries carry hrMetric:"awakeAvg" and older ones
     * are re-baked on sync so the series never mixes metrics.
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
     * Cache-first HR spikes: preferences.historicalHrSpikes, the per-day
     * spike cache incrementally maintained by LogRepository.
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
     * Middle-layer HR spikes: per-day "Biometrics" AiInsight entries (v6)
     * carry the day's spike count in the "spikes" key of their JSON payload
     * ({"sleepMins":N,...,"spikes":N}). A day counts as having spike data iff
     * the payload contains the "spikes" key — the same rule the web
     * dashboard's HR-spike graph uses. Note the documented ambiguity: a
     * "spikes":0 can mean a true zero-spike day OR spikes-unknown (the
     * insight generator defaults missing cache rows to 0). The dashboard
     * treats it as data, and we stay consistent with the dashboard.
     * Downstream only needs date + spikeCount.
     */
    private suspend fun readBiometricsSpikes(minDate: String): List<com.notel.notel.data.healthconnect.DailyHeartRateSummary> {
        return try {
            readBiometricsEntries(minDate).mapNotNull { (date, payload) ->
                val spikes = payload["spikes"]?.jsonPrimitive?.intOrNull ?: return@mapNotNull null
                com.notel.notel.data.healthconnect.DailyHeartRateSummary(
                    date = date,
                    avg = 0,
                    max = 0,
                    min = 0,
                    baseline = 0,
                    spikeCount = spikes,
                    maxDelta = 0,
                    totalReadings = 0
                )
            }
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
     * Cache-first sleep: per-day "Biometrics" AiInsight entries (v6) carry the
     * day's sleepMins. Zeros are never real (failed read) — dropped here.
     */

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
}

private data class ProfileTuple(
    val userContext: String,
    val age: Int,
    val height: Float,
    val weight: Float,
    val gender: String
)
