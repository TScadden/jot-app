package com.notel.notel.data.repository

import com.notel.notel.data.model.BiomarkerPoint

import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.GeminiService
import com.notel.notel.data.remote.BodyLoadResponse
import com.notel.notel.data.remote.ClassifyAndCleanResponse
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.data.sync.SyncManager
import com.notel.notel.data.repository.HabitRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import com.notel.notel.data.local.entity.AiInsight
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

data class DailyBiometricData(
    val hr: Int? = null,
    val sleep: Int? = null,
    val deepSleep: Int? = null,
    val cal: Int? = null,
    val hrv: Int? = null,
    val spikes: Int? = null
)

@Singleton
class LogRepository @Inject constructor(
    private val logEntryDao: LogEntryDao,
    private val geminiService: GeminiService,
    private val preferences: NotelPreferences,
    val healthConnectManager: HealthConnectManager,
    private val syncManager: SyncManager,
    private val categoryRepository: CategoryRepository,
    private val habitRepository: HabitRepository,
    private val lifecycleTracker: com.notel.notel.util.AppLifecycleTracker,
    private val tabsApi: com.notel.notel.data.remote.TabsApi,
    private val knowledgeDocumentDao: com.notel.notel.data.local.dao.KnowledgeDocumentDao,
    private val db: com.notel.notel.data.local.NotelDatabase,
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: android.content.Context
) {
    private val insightsMutex = Mutex()

    private val _isGeneratingReport = MutableStateFlow(false)
    val isGeneratingReport = _isGeneratingReport.asStateFlow()

    private val _generatedReport = MutableStateFlow<java.io.File?>(null)
    val generatedReport = _generatedReport.asStateFlow()

    private val _reportReadyEvent = MutableSharedFlow<java.io.File>()
    val reportReadyEvent = _reportReadyEvent.asSharedFlow()

    private val _isGeneratingWeeklyRecap = MutableStateFlow(false)
    val isGeneratingWeeklyRecap = _isGeneratingWeeklyRecap.asStateFlow()

    private val _isGeneratingDeepResearch = MutableStateFlow(false)
    val isGeneratingDeepResearch = _isGeneratingDeepResearch.asStateFlow()

    private val _isComparingDocuments = MutableStateFlow(false)
    val isComparingDocuments = _isComparingDocuments.asStateFlow()

    private val _aiInsightReadyEvent = MutableSharedFlow<AiInsight>()
    val aiInsightReadyEvent = _aiInsightReadyEvent.asSharedFlow()

    private val _processError = MutableStateFlow<String?>(null)
    val processError = _processError.asStateFlow()

    // Session-level cache for UI performance
    private val suggestionCache = mutableMapOf<Int, List<String>>()
    private var biometricCache: Map<String, Any>? = null
    private var lastBiometricFetch: Long = 0

    fun getCachedSuggestions(catId: Int): List<String>? {
        return suggestionCache[catId]
    }

    fun clearSuggestionCache() {
        suggestionCache.clear()
    }

    fun clearCache() {
        suggestionCache.clear()
        biometricCache = null
        lastBiometricFetch = 0
        _generatedReport.value = null
        _processError.value = null
        _isGeneratingReport.value = false
        _isGeneratingWeeklyRecap.value = false
        _isGeneratingDeepResearch.value = false
        _isComparingDocuments.value = false
    }

    fun resetGeneratedReport() {
        _generatedReport.value = null
    }

    fun clearProcessError() {
        _processError.value = null
    }

    fun setProcessError(err: String?) {
        _processError.value = err
    }

    @OptIn(DelicateCoroutinesApi::class)
    fun generateProfessionalReportAsync(allCategories: List<Category>, reportGenerator: com.notel.notel.util.ReportGenerator, last30DaysOnly: Boolean = false) {
        if (_isGeneratingReport.value) return
        _isGeneratingReport.value = true
        GlobalScope.launch {
            try {
                val entries = if (last30DaysOnly) {
                    val cutoff = System.currentTimeMillis() - (30L * 24 * 60 * 60 * 1000)
                    logEntryDao.getRecentEntriesInRange(cutoff, System.currentTimeMillis())
                } else {
                    logEntryDao.getRecentEntriesAll(limit = 2000)
                }
                val file = reportGenerator.generateReport(entries, allCategories, last30DaysOnly = last30DaysOnly)
                _generatedReport.value = file
                
                file?.let {
                    _reportReadyEvent.emit(it)
                    // Only show system notification if the app is NOT in the foreground
                    if (!lifecycleTracker.isAppInForeground.value) {
                        com.notel.notel.util.NotificationHelper(context).showReportReady(it)
                    }
                }
            } catch (e: Exception) {
                _processError.value = "Failed to generate report: ${e.message}"
            } finally {
                _isGeneratingReport.value = false
            }
        }
    }

    @OptIn(DelicateCoroutinesApi::class)
    fun generateWeeklyRecapAsync(allCategories: List<Category>) {
        if (_isGeneratingWeeklyRecap.value) return
        _isGeneratingWeeklyRecap.value = true
        GlobalScope.launch {
            try {
                getWeeklyRecap(allCategories).onFailure { e ->
                    _processError.value = "Weekly Recap Failed: ${e.message}"
                }
            } catch (e: Exception) {
                _processError.value = "Weekly Recap Failed: ${e.message}"
            } finally {
                _isGeneratingWeeklyRecap.value = false
            }
        }
    }

    @OptIn(DelicateCoroutinesApi::class)
    fun generateDeepResearchAsync(allCategories: List<Category>) {
        if (_isGeneratingDeepResearch.value) return
        _isGeneratingDeepResearch.value = true
        GlobalScope.launch {
            try {
                getDeepResearch(allCategories).onFailure { e ->
                    _processError.value = "Deep Advice Failed: ${e.message}"
                }
            } catch (e: Exception) {
                _processError.value = "Deep Advice Failed: ${e.message}"
            } finally {
                _isGeneratingDeepResearch.value = false
            }
        }
    }

    @OptIn(DelicateCoroutinesApi::class)
    fun generateDocumentComparisonAsync(allCategories: List<Category>) {
        if (_isComparingDocuments.value) return
        _isComparingDocuments.value = true
        GlobalScope.launch {
            try {
                getDocumentComparison(allCategories).onFailure { e ->
                    _processError.value = "Document Comparison Failed: ${e.message}"
                }
            } catch (e: Exception) {
                _processError.value = "Document Comparison Failed: ${e.message}"
            } finally {
                _isComparingDocuments.value = false
            }
        }
    }
    fun getAllEntries(): Flow<List<LogEntry>> = logEntryDao.getAllEntries()

    fun getEntriesByCategory(categoryId: Int): Flow<List<LogEntry>> =
        logEntryDao.getEntriesByCategory(categoryId)

    fun searchEntries(query: String): Flow<List<LogEntry>> =
        logEntryDao.searchEntries(query)

    private suspend fun clearTodayBodyLoadCache() {
        val todayStr = java.time.LocalDate.now().toString()
        clearBodyLoadInsightsForDays(listOf(todayStr))
    }

    suspend fun insertEntry(entry: LogEntry): Long {
        val entryToInsert = entry.copy(
            updatedAt = if (entry.updatedAt == 0L) System.currentTimeMillis() else entry.updatedAt,
            syncState = com.notel.notel.data.local.entity.EntrySyncState.DIRTY
        )
        val id = logEntryDao.insertEntry(entryToInsert)
        clearTodayBodyLoadCache()
        triggerSync()
        return id
    }

    suspend fun getRecentEntriesAll(limit: Int = 10): List<LogEntry> =
        logEntryDao.getRecentEntriesAll(limit)

    suspend fun updateEntry(entry: LogEntry) {
        val entryToUpdate = entry.copy(
            updatedAt = System.currentTimeMillis(),
            syncState = com.notel.notel.data.local.entity.EntrySyncState.DIRTY
        )
        logEntryDao.updateEntry(entryToUpdate)
        clearTodayBodyLoadCache()
        triggerSync()
    }

    suspend fun deleteEntry(entryId: Long) {
        val entry = getEntryById(entryId) ?: return
        deleteEntry(entry)
    }

    suspend fun deleteEntry(entry: LogEntry) {
        try {
            // 1. Local Delete
            logEntryDao.deleteEntry(entry)
            
            // 2. Cloud Delete (so it doesn't come back on the next sync)
            tabsApi.deleteEntry(entry.id)
            
            // 3. Trigger refresh
            clearTodayBodyLoadCache()
            triggerSync()
        } catch (e: Exception) {
            e.printStackTrace()
            // At least keep the local deleted
        }
    }
    
    @OptIn(DelicateCoroutinesApi::class)
    private fun triggerSync() {
        GlobalScope.launch {
            syncManager.syncAllData()
        }
    }

    fun getAllDocuments(): Flow<List<com.notel.notel.data.local.entity.KnowledgeDocument>> = 
        knowledgeDocumentDao.getAllDocuments()

    suspend fun deleteDocument(doc: com.notel.notel.data.local.entity.KnowledgeDocument) {
        // 1. Local Delete
        knowledgeDocumentDao.deleteDocument(doc)
        val file = File(doc.filePath)
        if (file.exists()) file.delete()
        
        // 2. Cloud Delete
        try {
            if (preferences.loggedIn.first()) {
                tabsApi.deleteDocument(doc.id)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        
        // 3. Trigger refresh
        triggerSync()
    }

    suspend fun clearAllDocuments() {
        knowledgeDocumentDao.getAllDocuments().first().forEach { 
            val file = File(it.filePath)
            if (file.exists()) file.delete()
        }
        knowledgeDocumentDao.deleteAll()
        triggerSync()
    }

    suspend fun getEntryById(id: Long): LogEntry? = logEntryDao.getEntryById(id)
    
    suspend fun getTodayJotCount(): Int {
        val todayStart = java.time.LocalDate.now().atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        return logEntryDao.getEntryCountSince(todayStart)
    }

    suspend fun getJotCountInRange(start: Long, end: Long): Int {
        return logEntryDao.getEntryCountInRange(start, end)
    }

    suspend fun getDailyStatsSummary(dateStr: String? = null, forceRefresh: Boolean = false): Map<String, Any> {
        val targetDay = dateStr ?: java.time.LocalDate.now().toString()
        val now = System.currentTimeMillis()
        
        // Use cache for any day if not forced and within 10 minutes
        if (!forceRefresh && biometricCache != null && (now - lastBiometricFetch) < 10 * 60 * 1000L) {
            val cachedData = biometricCache!!
            val hrvHistory = cachedData["hrvHistory"] as? List<Pair<String, Double>> ?: emptyList()
            val historyHr = cachedData["historyHr"] as? List<com.notel.notel.data.healthconnect.DailyHeartRateSummary> ?: emptyList()
            val sleepHistoryRecords = cachedData["sleepHistory"] as? List<Pair<String, Int>> ?: emptyList()
            val calorieHistory = cachedData["calorieHistory"] as? List<Pair<String, Int>> ?: emptyList()
            
            return extractDayFromCache(targetDay, hrvHistory, historyHr, sleepHistoryRecords, calorieHistory)
        }

        val isAvailable = healthConnectManager.checkAvailability() == androidx.health.connect.client.HealthConnectClient.SDK_AVAILABLE
        
        // Read cached heart rate spikes from preferences to merge
        val cachedHrList = try {
            val cachedStr = preferences.historicalHrSpikes.first()
            if (cachedStr.isNotBlank()) {
                Json { ignoreUnknownKeys = true }.decodeFromString<List<com.notel.notel.data.healthconnect.DailyHeartRateSummary>>(cachedStr)
            } else emptyList()
        } catch (e: Exception) {
            emptyList()
        }

        // 1. Fetch Historical Aggregates (42-day window for stable trends/ACWR, spikes cached up to 180 days)
        val hrvHistory = if (isAvailable) try { healthConnectManager.readHeartRateVariability(42) } catch(e: Exception) { emptyList() } else emptyList()
        
        // Heavy intraday heart rate query: if we already have 150+ cached days, query only the last 7 days and merge
        val historyHr = if (isAvailable) {
            try {
                val daysToQuery = if (cachedHrList.size >= 150) 7 else 180
                val freshHr = healthConnectManager.readHistoricalHeartRateWithSpikes(daysToQuery)
                val mergedMap = (cachedHrList + freshHr).associateBy { it.date }
                mergedMap.values.sortedByDescending { it.date }.take(180).sortedBy { it.date }
            } catch(e: Exception) {
                cachedHrList
            }
        } else {
            cachedHrList
        }

        val sleepHistoryRecords = if (isAvailable) try { healthConnectManager.readHistoricalSleep(42, targetDay) } catch(e: Exception) { emptyList() } else emptyList()
        val calorieHistory = if (isAvailable) try { healthConnectManager.readHistoricalCalories(42) } catch(e: Exception) { emptyList() } else emptyList()

        // UPDATE PREFERENCES TO FIX UI SYNC FOR 7 DAY RECAP
        try {
            val json = Json { ignoreUnknownKeys = true }
            val histHrList = historyHr.map { BiomarkerPoint(it.date, it.awakeAvg) }
            if (histHrList.isNotEmpty()) preferences.setHistoricalHeartRate(json.encodeToString(histHrList))
            
            val sleepList = sleepHistoryRecords.map { BiomarkerPoint(it.first, it.second) }
            if (sleepList.isNotEmpty()) preferences.setHistoricalSleep(json.encodeToString(sleepList))
            
            val calList = calorieHistory.map { BiomarkerPoint(it.first, it.second) }
            if (calList.isNotEmpty()) preferences.setHistoricalCalories(json.encodeToString(calList))
            
            if (historyHr.isNotEmpty()) preferences.setHistoricalHrSpikes(json.encodeToString(historyHr))

            // Also write today's awake-avg HR directly so BodyLoadViewModel's todayAwakeAvgHr
            // flow fires correctly for Health Connect users (previously only Fitbit set this).
            val todayStr = java.time.LocalDate.now().toString()
            val todayHrEntry = historyHr.find { it.date == todayStr }
            if (todayHrEntry != null && todayHrEntry.awakeAvg > 0) {
                preferences.setTodayAwakeAvgHr(todayHrEntry.awakeAvg)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }

        // Update cache
        biometricCache = mapOf(
            "hrvHistory" to hrvHistory, 
            "historyHr" to historyHr, 
            "sleepHistory" to sleepHistoryRecords,
            "calorieHistory" to calorieHistory
        )
        lastBiometricFetch = now

        return extractDayFromCache(targetDay, hrvHistory, historyHr, sleepHistoryRecords, calorieHistory)
    }

    private suspend fun extractDayFromCache(
        targetDay: String,
        hrvHistory: List<Pair<String, Double>>,
        historyHr: List<com.notel.notel.data.healthconnect.DailyHeartRateSummary>,
        sleepHistoryRecords: List<Pair<String, Int>>,
        calorieHistory: List<Pair<String, Int>> = emptyList()
    ): Map<String, Any> {
        val isAvailable = healthConnectManager.checkAvailability() == androidx.health.connect.client.HealthConnectClient.SDK_AVAILABLE
        
        // 2. Extract Target Day Biometrics
        val calories = calorieHistory.find { it.first == targetDay }?.second?.toInt() ?: 0
        
        // Use aggregated records for a more robust sleep duration (naps etc.)
        val sleepMins = sleepHistoryRecords.find { it.first == targetDay }?.second?.toDouble() ?: 0.0
        
        val currentHr = historyHr.find { it.date == targetDay }
        val rhr = currentHr?.baseline?.toDouble() ?: 70.0
        val hrv = hrvHistory.find { it.first == targetDay }?.second ?: 0.0
        
        // Match what is shown in the heart rate tab by using cached spikes
        val cachedSpikesStr = preferences.historicalHrSpikes.first()
        var spikeCount = 0.0
        if (cachedSpikesStr.isNotBlank()) {
            try {
                val spikes = Json { ignoreUnknownKeys = true }
                    .decodeFromString<List<com.notel.notel.data.healthconnect.DailyHeartRateSummary>>(cachedSpikesStr)
                spikeCount = spikes.find { it.date == targetDay }?.spikeCount?.toDouble() ?: 0.0
            } catch (e: Exception) { }
        }
        if (spikeCount == 0.0) {
            spikeCount = currentHr?.spikeCount?.toDouble() ?: 0.0
        }
        
        // 3. Baselines & Trends
        val hrvMean = if (hrvHistory.isNotEmpty()) hrvHistory.map { it.second }.average() else 45.0
        val hrvStd = if (hrvHistory.size > 2) calculateStdDev(hrvHistory.map { it.second }) else 10.0
        val rhrMean = if (historyHr.isNotEmpty()) historyHr.map { it.baseline.toDouble() }.average() else 70.0
        val rhrStd = if (historyHr.size > 2) calculateStdDev(historyHr.map { it.baseline.toDouble() }) else 5.0
        
        // 4. Activity Trends (ACWR) relative to targetDay
        val caloriesUpToDay = calorieHistory
            .filter { it.first <= targetDay }
            .sortedBy { it.first }
        val acuteCalories = caloriesUpToDay.takeLast(7).map { it.second }.average()
        val chronicCalories = caloriesUpToDay.takeLast(28).map { it.second }.average()
        val acwr = if (chronicCalories > 100) acuteCalories / chronicCalories else 1.0
        
        // 5. Sleep Debt calculation based on user script
        var totalDebt = 0.0
        val targetHours = 8.0
        val debtHistory = mutableListOf<Triple<String, Double, Double>>()
        
        sleepHistoryRecords
            .filter { it.first <= targetDay }
            .sortedBy { it.first }
            .takeLast(10) // Rolling 10-day window
            .forEach { (day, minutes) ->
                val actualHours = minutes / 60.0
                if (actualHours < targetHours) {
                    // Add to the debt
                    totalDebt += (targetHours - actualHours)
                } else {
                    // Surplus reduces debt slightly, capped at 1.5h per night
                    val surplus = actualHours - targetHours
                    totalDebt -= Math.min(surplus, 1.5)
                }
                // Debt cannot drop below zero
                totalDebt = Math.max(0.0, totalDebt)
                
                // We'll store (date, dailyDelta, runningBalance)
                // Negate totalDebt for UI balance consistency (negative = deficit)
                debtHistory.add(Triple(day, actualHours - targetHours, -totalDebt))
            }
        
        val sleepDebt = -totalDebt
        val sleepDebtHistory = debtHistory
        
        // Jots for the 7 days
        val dateObj = if (targetDay != null) try { java.time.LocalDate.parse(targetDay) } catch(e: Exception) { java.time.LocalDate.now() } else java.time.LocalDate.now()
        val endTs = dateObj.atTime(23, 59).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        val startTs = endTs - (7L * 24 * 60 * 60 * 1000L)
        val startOfDayTs = dateObj.atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        val jotCount = logEntryDao.getEntryCountInRange(startTs, endTs).toDouble()
        val jotCountDaily = logEntryDao.getEntryCountInRange(startOfDayTs, endTs).toDouble()
        
        val targetHrSummary = historyHr.find { it.date == targetDay }
        val awakeAvg = targetHrSummary?.awakeAvg?.toDouble() ?: 0.0

        return mapOf(
            "calories" to calories.toDouble(),
            "sleepMins" to sleepMins,
            "spikeCount" to spikeCount,
            "jotCount" to jotCount,
            "jotCountDaily" to jotCountDaily,
            "hrv" to hrv,
            "hrvMean" to hrvMean,
            "hrvStd" to hrvStd,
            "rhr" to rhr,
            "rhrMean" to rhrMean,
            "rhrStd" to rhrStd,
            "acwr" to acwr,
            "sleepDebtHistory" to sleepDebtHistory,
            "sleepDebt" to sleepDebt,
            "awakeAvg" to awakeAvg
        )
    }

    private fun calculateStdDev(values: List<Double>): Double {
        if (values.isEmpty()) return 1.0
        val avg = values.average()
        return Math.sqrt(values.sumOf { (it - avg) * (it - avg) } / values.size)
    }

    /**
     * Fetches AI chip suggestions for the given [category].
     * Pulls recent history from Room for context, then calls Gemini.
     */
    suspend fun getChipSuggestions(category: Category, forceRefresh: Boolean = false): Result<List<String>> {
        if (!forceRefresh && suggestionCache.containsKey(category.id)) {
            return Result.success(suggestionCache[category.id]!!)
        }

        val isUnlimited = preferences.isUnlimited.first()
        if (!isUnlimited) return Result.failure(IllegalStateException("Unlimited membership required for AI features. Please check Membership in Settings."))

        val recent = logEntryDao.getRecentEntries(category.id, limit = 20)
        val context = getEnrichedUserContext() + 
            "\n\n[SYSTEM: SUGGESTION_ENGINE_RULES]\n" +
            "Return 6-10 'Quick Note' chips. Rules:\n" +
            "1. STRICTURE: Each chip MUST BE 20 CHARACTERS OR LESS (including spaces).\n" +
            "2. Each chip MUST be 1-3 words total.\n" +
            "3. Focus only on specific symptoms, actions, or status updates appropriate for the category '${category.name}'.\n" +
            "4. NO full sentences. NO punctuation. NO trailing conjunctions ('and', 'with', 'for').\n" +
            "5. Use clear health abbreviations if necessary (e.g., 'RLS', 'POTs', 'OI', 'MCAS').\n" +
            "6. Priorities matching current user data (HR spikes, sleep debt, past logs).\n" +
            "Example: 'Brain Fog', 'Chest Pain', 'High HR Spike', 'Restless Legs'."
        
        val weather = getWeatherContext()
        
        // Removed knowledgeBase from chip suggestions to prevent hitting the TPM (Tokens Per Minute) limit.
        // The userContext (summary) is sufficient for generating 1-3 word chips.
        return geminiService.getSuggestions(category, recent, userContext = context, knowledgeBase =
            "", weatherContext = weather).onSuccess { list ->
            suggestionCache[category.id] = list
        }
    }

    suspend fun getSmartCategorySuggestion(existingCategories: List<String>): Result<List<com.notel.notel.data.remote.SmartCategorySuggestion>> {
        val isUnlimited = preferences.isUnlimited.first()
        if (!isUnlimited) return Result.success(emptyList()) // Silently fail if no access

        val recent = logEntryDao.getRecentEntriesAll(limit = 50)
        val userContext = getEnrichedUserContext()
        
        return geminiService.getSmartCategorySuggestion(recent, existingCategories, userContext)
    }

    suspend fun validateCategoryName(name: String): Result<String> {
        return geminiService.validateCategoryName(name)
    }

    private suspend fun getWeatherContext(): String? {
        return try {
            val lat = preferences.lastKnownLat.first()
            val lon = preferences.lastKnownLon.first()
            val city = preferences.lastKnownCity.first()
            if (lat == 0.0) return null
            
            com.notel.notel.data.remote.WeatherApi().getDetailedWeather(lat, lon, city)?.let { info ->
                "ENVIRONMENTAL CONTEXT:\n- Location: ${info.locationName}\n- Temp: ${info.temp}°${info.unit}\n- Condition: ${info.condition}\n- Humidity: ${info.humidity}%\n- Wind: ${info.windSpeed} km/h\n- Pressure: ${info.pressure} hPa\n- UV Index: ${info.uvIndex}"
            }
        } catch (e: Exception) { null }
    }

    private suspend fun getEnrichedUserContext(): String {
        val baseContext = preferences.userContext.first()
        val lastUpdate = preferences.userContextLastUpdate.first()
        val updateDate = if (lastUpdate > 0) java.text.SimpleDateFormat("MMM dd, yyyy", java.util.Locale.US).format(java.util.Date(lastUpdate)) else "Unknown"
        
        val gender = preferences.userGender.first()
        val age = preferences.userAge.first()
        val height = preferences.userHeight.first()
        val weight = preferences.userWeight.first()
        val demographicStats = "Profile Info: Gender: $gender, Age: $age, Height: ${height}cm, Weight: ${weight}lbs"
        
        val header = "📋 USER BACKGROUND CONTEXT (Last Updated: $updateDate):\n$baseContext\n$demographicStats\n\n"
        
        val countersJson = preferences.eventCounters.first()
        if (countersJson.isBlank() || countersJson == "[]") return header
        
        var counterContext = ""
        try {
            val counters = kotlinx.serialization.json.Json.decodeFromString<List<com.notel.notel.ui.viewmodel.EventCounterDto>>(countersJson)
            if (counters.isNotEmpty()) {
                val sb = java.lang.StringBuilder("⏰ ACTIVE EVENT COUNTERS (CHRONOLOGICAL PRIORITY):\n")
                sb.append("Rule: Use these dates to determine the user's current status (e.g., 'X days since event Y').\n")
                counters.forEach { counter ->
                    val targetLocalDate = java.time.Instant.ofEpochMilli(counter.targetDate)
                        .atZone(java.time.ZoneId.systemDefault())
                        .toLocalDate()
                    val today = java.time.LocalDate.now()
                    
                    val diffDays = java.time.temporal.ChronoUnit.DAYS.between(targetLocalDate, today)
                    var isUp = counter.isUp
                    var finalDays = diffDays
                    
                    if (!isUp && diffDays > 0 && counter.autoUp) {
                        isUp = true
                        finalDays = diffDays
                    } else if (isUp) {
                        finalDays = diffDays
                    } else {
                        finalDays = -diffDays // "Until"
                    }
                    
                    if (isUp || diffDays <= 0) {
                        val daysRemaining = Math.max(0L, finalDays)
                        val direction = if (isUp) "since" else "until"
                        val startDate = java.text.SimpleDateFormat("MMM dd, yyyy", java.util.Locale.US).format(java.util.Date(counter.targetDate))
                        val archivedTag = if (counter.isArchived) "[ARCHIVED] " else ""
                        sb.append("- ${archivedTag}${counter.name}: ${daysRemaining} days ${direction} (Started/Target: $startDate)\n")
                    }
                }
                counterContext = sb.toString()
            }
        } catch (e: Exception) {
            // ignore
        }
        
        return if (counterContext.isNotEmpty()) {
            "$header$counterContext"
        } else {
            header
        }
    }

    private suspend fun getEnrichedKnowledgeBase(): String {
        val kb = preferences.knowledgeBase.first()
        val proUpdates = preferences.professionalUpdates.first()
        if (proUpdates.isBlank()) return kb

        // Professional updates are date-stamped and override personal context.
        // Build a header that makes the recency priority crystal-clear to the AI.
        val proSection = buildString {
            append("⚠️ PROFESSIONAL / DOCTOR INSTRUCTIONS (HIGHEST PRIORITY — OVERRIDES PERSONAL CONTEXT):\n")
            append("RULE: If a professional instruction conflicts with anything in the user's personal context or knowledge base,\n")
            append("      the MOST RECENT dated professional instruction ALWAYS wins. Treat these as binding clinical directives.\n\n")
            // Split on blank lines so each update is a separate entry
            val updates = proUpdates.split("\n\n").filter { it.isNotBlank() }
            updates.forEach { update -> append("• $update\n\n") }
            append("(If two instructions conflict, the one with the more recent date takes precedence.)\n")
        }

        return if (kb.isBlank()) proSection else "$proSection\n---\nKNOWLEDGE BASE / UPLOADED DOCUMENTS (reference, lower priority than professional instructions):\n$kb"
    }

    private suspend fun getHabitDataSummary(targetDate: String? = null): String {
        val habits = habitRepository.habits.first()
        if (habits.isEmpty()) return ""
        val today = java.time.LocalDate.now()
        val sb = StringBuilder()
        
        val allLogsTotallyEmpty = habits.all { it.logs.isEmpty() }
        
        sb.append("HABIT TRACKER LOGS (Chronological for Correlation):\n")
        
        if (allLogsTotallyEmpty) {
            sb.append("- [STREAK DATA UNAVAILABLE / ALL HISTORICAL HABIT LOGS RECENTLY CLEARED BY USER]\n")
        } else {
            sb.append("Format: Date: [Habits completed on this day]\n")
            var hasAnyLog = false
            
            val daysToLog = if (targetDate != null) listOf(targetDate) else (0..14).map { today.minusDays(it.toLong()).format(java.time.format.DateTimeFormatter.ISO_LOCAL_DATE) }
            
            for (dateStr in daysToLog) {
                val completed = habits.filter { it.logs.contains(dateStr) }.map { it.title }
                if (completed.isNotEmpty()) {
                    hasAnyLog = true
                    sb.append("- $dateStr: ${completed.joinToString(", ")}\n")
                }
            }
            if (!hasAnyLog) {
                sb.append("- No habits logged for the requested period.\n")
            }
        }
        
        sb.append("\nHABIT COMPLETION STATISTICS (Summary for the End of Report):\n")
        sb.append("NOTE: Only include these stats in a 'Habit Completion' section at the literal end of the PDF report.\n")
        if (allLogsTotallyEmpty) {
            sb.append("CRITICAL: ALL STATS ARE 0 DUE TO DATA RESET.\n")
        }
        
        habits.forEach { habit ->
            val streak = run {
                var s = 0
                var d = java.time.LocalDate.now()
                while (habit.logs.contains(d.format(java.time.format.DateTimeFormatter.ISO_LOCAL_DATE))) {
                    s++
                    d = d.minusDays(1)
                }
                s
            }
            
            // Calculate completion rate for the last 10 days
            var completedCount = 0
            val missedDates = mutableListOf<String>()
            for (i in 0..9) {
                val d = today.minusDays(i.toLong())
                val dStr = d.format(java.time.format.DateTimeFormatter.ISO_LOCAL_DATE)
                if (habit.logs.contains(dStr)) {
                    completedCount++
                } else {
                    missedDates.add(dStr)
                }
            }
            
            sb.append("- ${habit.title}: Current Streak: $streak days | Completion: $completedCount/10 days")
            if (missedDates.isNotEmpty()) {
                sb.append(" (Missed: ${missedDates.joinToString(", ")})")
            }
            sb.append("\n")
        }
        
        sb.append("\nAI REPORT INSTRUCTION: Do NOT just list habits in the main medical summary. ONLY mention a habit in the medical trends section IF there is a visible correlation (e.g., 'symptoms decreased after habit X was completed'). MOVE the raw habit streaks and completion rates to the FINAL section of the report.")
        
        return sb.toString()
    }

    /**
     * Asks Gemini to analyse the last 10 entries across ALL categories
     * and return actionable health observations.
     */
    suspend fun getAdvice(allCategories: List<com.notel.notel.data.local.entity.Category>): Result<String> {
        val recent = logEntryDao.getRecentEntriesAll(limit = 20)
        val catMap = allCategories.associate { it.id to it.name }
        val context = getEnrichedUserContext()
        val kb = getEnrichedKnowledgeBase()
        val pastInsights = getPastInsightsText()
        val hasHealthConnect = healthConnectManager.hasAllPermissions()
        val fitbitToken = preferences.fitbitToken.first()
        
        val fitbitData = getFitbitDataSummary()
        val habitData = getHabitDataSummary()
        
        val isUnlimited = preferences.isUnlimited.first()
        if (!isUnlimited) return Result.failure(IllegalStateException("Unlimited membership required for AI features. Please check Membership in Settings."))

        val documents = getEnrichedDocuments()
        val weather = getWeatherContext()

        val result = geminiService.getAdvice(recent, catMap, userContext = context, knowledgeBase = kb, pastInsights = pastInsights, fitbitData = fitbitData, habitData = habitData, weatherContext = weather, documents = documents)
        result.onSuccess { text ->
            saveAiInsight(text, "Advice")
        }
        return result
    }

    suspend fun getMedicalReportSummary(allCategories: List<Category>, last30DaysOnly: Boolean = false): Result<String> {
        val recent = if (last30DaysOnly) {
            val cutoff = System.currentTimeMillis() - (30L * 24 * 60 * 60 * 1000)
            logEntryDao.getRecentEntriesInRange(cutoff, System.currentTimeMillis())
        } else {
            logEntryDao.getRecentEntriesAll(limit = 2000)
        }
        
        // Calculate the exact date range of the entries provided to the AI
        val dateSpanText = if (recent.isNotEmpty()) {
            val timestamps = recent.map { it.timestamp }
            val minDate = java.text.SimpleDateFormat("MMMM d, yyyy", java.util.Locale.US).format(java.util.Date(timestamps.minOrNull() ?: System.currentTimeMillis()))
            val maxDate = java.text.SimpleDateFormat("MMMM d, yyyy", java.util.Locale.US).format(java.util.Date(timestamps.maxOrNull() ?: System.currentTimeMillis()))
            val totalDays = ((timestamps.maxOrNull() ?: System.currentTimeMillis()) - (timestamps.minOrNull() ?: System.currentTimeMillis())) / (24 * 60 * 60 * 1000L) + 1
            "REPORT TIME SPAN: $minDate to $maxDate ($totalDays Days Total)"
        } else "REPORT TIME SPAN: Empty"

        val catMap = allCategories.associate { it.id to it.name }
        val context = "${getEnrichedUserContext()}\n\n$dateSpanText"
        val kb = getEnrichedKnowledgeBase()
        val pastInsights = getPastInsightsText()
        val hasHealthConnect = healthConnectManager.hasAllPermissions()
        val fitbitToken = preferences.fitbitToken.first()
        
        val fitbitData = getFitbitDataSummary(last30DaysOnly = last30DaysOnly)
        // Habits are UI-only for personal tracking; excluded from the PDF report.
        val habitData = ""
        
        val isUnlimited = preferences.isUnlimited.first()
        if (!isUnlimited) return Result.failure(IllegalStateException("Unlimited membership required for AI features. Please check Membership in Settings."))

        val bodyLoadHistory = getBodyLoadHistorySummary()

        var attempts = 3
        var finalResult: Result<String> = Result.failure(Exception("Initial"))
        
        while (attempts > 0) {
            finalResult = geminiService.getMedicalReportSummary(
                recent, 
                catMap, 
                userContext = context, 
                knowledgeBase = kb, 
                pastInsights = pastInsights, 
                fitbitData = fitbitData, 
                habitData = habitData,
                bodyLoadHistory = bodyLoadHistory,
                weatherContext = getWeatherContext(),
                documents = getEnrichedDocuments()
            )
            
            if (finalResult.isSuccess) break
            
            attempts--
            if (attempts > 0) kotlinx.coroutines.delay(1000L) // Wait 1s and try again
        }

        finalResult.onSuccess { text ->
            saveAiInsight(text, "Report")
        }
        return finalResult
    }

    suspend fun getWeeklyRecap(allCategories: List<Category>): Result<String> {
        // Fetch last 7 days of entries (this is a simplified proxy by grabbing recent entries)
        val recent = logEntryDao.getRecentEntriesAll(limit = 35) // Approx 5 entries a day for a week
        val catMap = allCategories.associate { it.id to it.name }
        val context = getEnrichedUserContext()
        val kb = getEnrichedKnowledgeBase()
        val hasHealthConnect = healthConnectManager.hasAllPermissions()
        val fitbitToken = preferences.fitbitToken.first()
        
        val fitbitData = getFitbitDataSummary()
        val habitData = getHabitDataSummary()

        val weather = getWeatherContext()

        val result = geminiService.getWeeklyRecap(recent, catMap, userContext = context, knowledgeBase = kb, fitbitData = fitbitData, habitData = habitData, weatherContext = weather, documents = getEnrichedDocuments())
        result.onSuccess { text ->
            saveAiInsight(text, "Weekly Recap")
        }
        return result
    }

    suspend fun getDeepResearch(allCategories: List<Category>): Result<String> {
        // Fetch up to 90 days of entries (get as much context as possible)
        val recent = logEntryDao.getRecentEntriesAll(limit = 150)
        val catMap = allCategories.associate { it.id to it.name }
        val context = getEnrichedUserContext()
        val kb = getEnrichedKnowledgeBase()
        val pastInsights = getPastInsightsText()
        val hasHealthConnect = healthConnectManager.hasAllPermissions()
        val fitbitToken = preferences.fitbitToken.first()

        val fitbitData = getFitbitDataSummary()
        val habitData = getHabitDataSummary()

        val weather = getWeatherContext()

        val result = geminiService.getDeepResearch(recent, catMap, userContext = context, knowledgeBase = kb, pastInsights = pastInsights, fitbitData = fitbitData, habitData = habitData, weatherContext = weather, documents = getEnrichedDocuments())
        result.onSuccess { text ->
            saveAiInsight(text, "Deep Advice")
        }
        return result
    }
    
    suspend fun getDocumentComparison(allCategories: List<Category>): Result<String> {
        // Fetch up to 30 days of entries (compare past month)
        val recent = logEntryDao.getRecentEntriesAll(limit = 100)
        val catMap = allCategories.associate { it.id to it.name }
        val context = getEnrichedUserContext()
        val kb = getEnrichedKnowledgeBase()
        if (kb.isBlank()) return Result.failure(IllegalStateException("No documents to compare against"))
        
        val pastInsights = getPastInsightsText()
        val hasHealthConnect = healthConnectManager.hasAllPermissions()

        val fitbitData = getFitbitDataSummary()
        val habitData = getHabitDataSummary()

        val weather = getWeatherContext()

        val result = geminiService.getDocumentComparison(recent, catMap, userContext = context, knowledgeBase = kb, pastInsights = pastInsights, fitbitData = fitbitData, habitData = habitData, weatherContext = weather, documents = getEnrichedDocuments())
        result.onSuccess { text ->
            saveAiInsight(text, "Document Comparison")
        }
        return result
    }
    
    private suspend fun getPastInsightsText(): String {
        val insightsStr = preferences.aiInsights.first()
        val insights: List<AiInsight> = try {
            if (insightsStr.isNotBlank()) Json.decodeFromString<List<AiInsight>>(insightsStr) else emptyList()
        } catch(e: Exception) { emptyList() }
        if (insights.isEmpty()) return ""
        // Exclude full "Reports" from the context to prevent the AI from just repeating the previous PDF output.
        // We want advice and recaps, but not a loop of previous reports.
        return insights.filter { it.type != "Report" && it.type != "Professional Report" }
            .take(5)
            .joinToString("\n") { "[${it.type}] ${it.text}" }
    }
    
    private suspend fun getBodyLoadHistorySummary(): String {
        val insightsStr = preferences.aiInsights.first()
        val insights: List<AiInsight> = try {
            if (insightsStr.isNotBlank()) Json.decodeFromString<List<AiInsight>>(insightsStr) else emptyList()
        } catch(e: Exception) { return "" }
        
        val bodyLoads = insights.filter { it.type == "BodyLoad" }
            .filter { (System.currentTimeMillis() - it.timestamp) < (7L * 24 * 60 * 60 * 1000) }
        
        val scores = bodyLoads.mapNotNull { insight ->
            if (insight.text.contains("Cup %: ")) {
                insight.text.substringAfter("Cup %: ").substringBefore(" |").trim().toIntOrNull()
            } else {
                insight.text.substringAfter("Body Load: ").substringBefore(" |").trim().toIntOrNull()
            }
        }

        val factors = bodyLoads.flatMap { insight ->
            insight.text.substringAfter("Factors: ").split(", ").filter { it.isNotBlank() }
        }
        
        val topFactors = factors.groupingBy { it }.eachCount().toList()
            .sortedByDescending { it.second }.take(3).joinToString(", ") { it.first }

        if (scores.isEmpty()) return "Trend data pending (requires daily analysis)."
        
        val min = scores.minOrNull() ?: 0
        val max = scores.maxOrNull() ?: 0
        val avg = scores.average().toInt()
        
        val commonStr = if (topFactors.isNotEmpty()) " Recurring Hindrances: $topFactors." else ""
        
        return if (scores.size == 1) {
            "Recent Body Load Trend: Baseline set at $min/100.$commonStr"
        } else {
            "Recent Body Load Trend: Range $min/100 to $max/100 (Average: $avg/100).$commonStr"
        }
    }
    suspend fun sendCoachMessage(
        messages: List<com.notel.notel.data.remote.CoachMessageDto>,
        userContext: String? = null,
        knowledgeBase: String? = null,
        recentEntries: List<LogEntry> = emptyList()
    ): Result<String> {
        return try {
            if (!preferences.loggedIn.first()) return Result.failure(Exception("Not logged in"))
            
            val bodyLoadHistory = getBodyLoadHistorySummary()
            
            val request = com.notel.notel.data.remote.CoachRequest(
                messages = messages,
                userContext = userContext,
                knowledgeBase = knowledgeBase,
                recentEntries = recentEntries.map { com.notel.notel.data.remote.LogEntryDtoModel(it.id, it.categoryId, it.body, it.chips, it.manualText, it.timestamp) },
                bodyLoadHistory = bodyLoadHistory
            )
            
            val response = tabsApi.getCoachReply(request)
            if (response.isSuccessful) {
                response.body()?.result?.let {
                    Result.success(it)
                } ?: Result.failure(Exception("Empty reply from server"))
            } else {
                Result.failure(Exception(response.errorBody()?.string() ?: "Unknown error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun generateCoachTitle(firstMessage: String): Result<String> {
        return try {
            if (!preferences.loggedIn.first()) return Result.failure(Exception("Not logged in"))
            
            val request = com.notel.notel.data.remote.TitleRequest(firstMessage)
            val response = tabsApi.getCoachTitle(request)
            
            if (response.isSuccessful) {
                response.body()?.title?.let {
                    Result.success(it)
                } ?: Result.failure(Exception("Empty reply from server"))
            } else {
                Result.failure(Exception(response.errorBody()?.string() ?: "Unknown error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    
    suspend fun saveAiInsight(text: String, type: String, timestamp: Long? = null, entryId: Long? = null, requestId: String? = null) = insightsMutex.withLock {
        val insightsStr = preferences.aiInsights.first()
        val insights: MutableList<AiInsight> = try {
            if (insightsStr.isNotBlank()) Json.decodeFromString<MutableList<AiInsight>>(insightsStr) else mutableListOf()
        } catch(e: Exception) { mutableListOf() }
        
        val ts = timestamp ?: System.currentTimeMillis()
        
        // Remove existing BodyLoad insight for the same day to prevent duplicates
        val insightId = if (type == "BodyLoad") {
            val date = java.time.Instant.ofEpochMilli(ts).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
            "bodyload_$date"
        } else {
            requestId ?: java.util.UUID.randomUUID().toString()
        }
        val newInsight = AiInsight(id = insightId, text = text, timestamp = ts, type = type, entryId = entryId, requestId = requestId)
        insights.add(0, newInsight)
        preferences.setAiInsights(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(AiInsight.serializer()), insights.take(1000))) // Keep last 1000
        
        _aiInsightReadyEvent.emit(newInsight)
        
        triggerSync()
    }

    suspend fun notifyNewAiInsight(insight: AiInsight) {
        _aiInsightReadyEvent.emit(insight)
    }

    suspend fun saveAiInsightsBulk(newEntries: List<AiInsight>) = insightsMutex.withLock {
        if (newEntries.isEmpty()) return
        val insightsStr = preferences.aiInsights.first()
        val insights: MutableList<AiInsight> = try {
            if (insightsStr.isNotBlank()) Json.decodeFromString<MutableList<AiInsight>>(insightsStr) else mutableListOf()
        } catch(e: Exception) { mutableListOf() }
        
        newEntries.forEach { newOn ->
            // Minimal duplicate check (day-level)
            val exists = insights.any { it.type == newOn.type && Math.abs(it.timestamp - newOn.timestamp) < 6 * 60 * 60 * 1000 }
            if (!exists) insights.add(0, newOn)
        }
        
        preferences.setAiInsights(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(AiInsight.serializer()), insights.take(1000))) // Keep last 1000
        triggerSync()
    }

    suspend fun clearBodyLoadInsightsForDays(days: List<String>) = insightsMutex.withLock {
        val insightsStr = preferences.aiInsights.first()
        val insights: MutableList<AiInsight> = try {
            if (insightsStr.isNotBlank()) Json.decodeFromString<MutableList<AiInsight>>(insightsStr) else mutableListOf()
        } catch(e: Exception) { mutableListOf() }
        
        var modified = false
        days.forEach { dateStr ->
            val targetLocalDate = try { java.time.LocalDate.parse(dateStr) } catch(e: Exception) { java.time.LocalDate.now() }
            val startOfDay = targetLocalDate.atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
            val removed = insights.removeAll { it.type == "BodyLoad" && isSameDay(it.timestamp, startOfDay) }
            if (removed) {
                modified = true
            }
        }
        
        if (modified) {
            preferences.setAiInsights(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(AiInsight.serializer()), insights))
            triggerSync()
        }
    }

    suspend fun ingestDocumentFile(fileName: String, mimeType: String, base64Data: String): Result<Unit> {
        return try {
            val dir = File(context.filesDir, "knowledge_docs")
            if (!dir.exists()) dir.mkdirs()
            
            val file = File(dir, "${UUID.randomUUID()}_$fileName")
            val bytes = android.util.Base64.decode(base64Data, android.util.Base64.DEFAULT)
            file.writeBytes(bytes)
            
            val doc = com.notel.notel.data.local.entity.KnowledgeDocument(
                name = fileName,
                mimeType = mimeType,
                filePath = file.absolutePath
            )
            knowledgeDocumentDao.insertDocument(doc)
            
            // Track that we processed this file in old format too for compatibility if needed
            val currentFiles = preferences.processedFiles.first()
            val updatedFiles = if (currentFiles.isBlank()) fileName else "$fileName, $currentFiles"
            preferences.setProcessedFiles(updatedFiles)

            // ── Extract text once via Gemini and cache it ─────────────────────
            // This runs as a background task so the UI doesn't block.
            // Any failure here is non-fatal — the document is already saved.
            @OptIn(kotlinx.coroutines.DelicateCoroutinesApi::class)
            kotlinx.coroutines.GlobalScope.launch {
                try {
                    val extracted = geminiService.processDocumentFile(mimeType, base64Data)
                    extracted.onSuccess { text ->
                        if (text.isNotBlank()) {
                            knowledgeDocumentDao.updateExtractedText(doc.id, text)
                        }
                    }
                } catch (e: Exception) {
                    // Non-fatal: extraction failed, will fall back to inline data at report time
                    e.printStackTrace()
                }
            }
            
            triggerSync()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun ingestPreExtractedDocumentFile(
        fileName: String,
        mimeType: String,
        base64Data: String,
        extractedText: String
    ): Result<Unit> {
        return try {
            val dir = File(context.filesDir, "knowledge_docs")
            if (!dir.exists()) dir.mkdirs()
            
            val file = File(dir, "${UUID.randomUUID()}_$fileName")
            val bytes = android.util.Base64.decode(base64Data, android.util.Base64.DEFAULT)
            file.writeBytes(bytes)
            
            val doc = com.notel.notel.data.local.entity.KnowledgeDocument(
                name = fileName,
                mimeType = mimeType,
                filePath = file.absolutePath,
                extractedText = extractedText
            )
            knowledgeDocumentDao.insertDocument(doc)
            
            // Track that we processed this file in old format too for compatibility if needed
            val currentFiles = preferences.processedFiles.first()
            val updatedFiles = if (currentFiles.isBlank()) fileName else "$fileName, $currentFiles"
            preferences.setProcessedFiles(updatedFiles)
            
            triggerSync()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }


    private suspend fun getEnrichedDocuments(): List<com.notel.notel.data.remote.ProcessDocumentRequest> {
        val docs = knowledgeDocumentDao.getAllDocuments().first()
        return docs.mapNotNull { doc ->
            try {
                // If we already extracted text, send it as plain text (no base64 re-read = no API cost)
                if (!doc.extractedText.isNullOrBlank()) {
                    val textB64 = android.util.Base64.encodeToString(
                        doc.extractedText.toByteArray(Charsets.UTF_8),
                        android.util.Base64.NO_WRAP
                    )
                    com.notel.notel.data.remote.ProcessDocumentRequest("text/plain", textB64)
                } else {
                    // Fallback: send raw file so the server can extract it for the first time
                    val file = File(doc.filePath)
                    if (file.exists()) {
                        val bytes = file.readBytes()
                        val b64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
                        com.notel.notel.data.remote.ProcessDocumentRequest(doc.mimeType, b64)
                    } else null
                }
            } catch (e: Exception) { null }
        }
    }

    suspend fun ingestTextNote(title: String, text: String): Result<Unit> {
        val base64 = android.util.Base64.encodeToString(text.toByteArray(), android.util.Base64.NO_WRAP)
        return ingestDocumentFile(title, "text/plain", base64)
    }

    /**
     * Reads an existing document from disk, sends it to Gemini for text extraction,
     * and caches the result in Room. No-ops if the file doesn't exist or text is already cached.
     * Safe to call multiple times — only does work when extractedText is missing.
     */
    suspend fun extractAndCacheDocumentText(doc: com.notel.notel.data.local.entity.KnowledgeDocument) {
        if (!doc.extractedText.isNullOrBlank()) return // already done
        try {
            val file = File(doc.filePath)
            if (!file.exists()) return
            val bytes = file.readBytes()
            val b64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
            val result = geminiService.processDocumentFile(doc.mimeType, b64)
            result.onSuccess { text ->
                if (text.isNotBlank()) {
                    knowledgeDocumentDao.updateExtractedText(doc.id, text)
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    /** Persists a user-edited correction to the cached extracted text. */
    suspend fun updateDocumentExtractedText(docId: String, newText: String) {
        knowledgeDocumentDao.updateExtractedText(docId, newText)
    }

    suspend fun getAiExtraction(prompt: String): Result<String> {
        return geminiService.getAdvice(
            recentEntries = emptyList(),
            categories = emptyMap(),
            userContext = prompt
        )
    }

    suspend fun clearKnowledgeBase() {
        preferences.setKnowledgeBase("")
        preferences.setProcessedFiles("")
        triggerSync()
    }

    suspend fun deleteKnowledgeItem(index: Int) {
        val currentKb = preferences.knowledgeBase.first()
        val facts = currentKb.split("\n\n").filter { it.isNotBlank() }.toMutableList()
        val currentFiles = preferences.processedFiles.first()
        val files = currentFiles.split(",").map { it.trim() }.filter { it.isNotBlank() }.toMutableList()
        
        if (index in facts.indices) {
            facts.removeAt(index)
            preferences.setKnowledgeBase(facts.joinToString("\n\n"))
            
            if (index in files.indices) {
                files.removeAt(index)
                preferences.setProcessedFiles(files.joinToString(", "))
            }
            triggerSync()
        }
    }

    private suspend fun getFitbitDataSummary(targetDate: String? = null, last30DaysOnly: Boolean = false): String {
        val hasHealthConnect = healthConnectManager.hasAllPermissions()
        val fitbitToken = preferences.fitbitToken.first()
        if (!hasHealthConnect && fitbitToken.isBlank()) return ""

        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        val daysLimit = if (last30DaysOnly) 31 else 180

        // ── Spike-aware heart rate (POTS/MCAS critical) ───────────────────────
        val spikesJson = preferences.historicalHrSpikes.first()
        val spikeHistory: List<DailyHeartRateSummary> = if (spikesJson.isNotBlank()) {
            try { json.decodeFromString(spikesJson) } catch (e: Exception) { emptyList() }
        } else if (hasHealthConnect) {
            val fresh = healthConnectManager.readHistoricalHeartRateWithSpikes(daysLimit)
            if (fresh.isNotEmpty()) {
                preferences.setHistoricalHrSpikes(kotlinx.serialization.json.Json.encodeToString(fresh))
            }
            fresh
        } else emptyList()

        val heartJson = preferences.historicalHeartRate.first()
        val heartHist = try {
            if (heartJson.isNotBlank()) json.decodeFromString<List<BiomarkerPoint>>(heartJson).map { it.date to it.value }
            else if (hasHealthConnect) healthConnectManager.readHistoricalHeartRate(180)
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val sleepJson = preferences.historicalSleep.first()
        val sleepHist = try {
            if (sleepJson.isNotBlank()) json.decodeFromString<List<BiomarkerPoint>>(sleepJson).map { it.date to it.value }
            else if (hasHealthConnect) healthConnectManager.readHistoricalSleep(180)
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val sleepWithDeepHist = try {
            if (hasHealthConnect) healthConnectManager.readHistoricalSleepWithDeep(180)
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val calJson = preferences.historicalCalories.first()
        val calHist = try {
            if (calJson.isNotBlank()) json.decodeFromString<List<BiomarkerPoint>>(calJson).map { it.date to it.value }
            else if (hasHealthConnect) healthConnectManager.readHistoricalCalories(180)
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val hrvHist = try {
            if (hasHealthConnect) healthConnectManager.readHeartRateVariability(180)
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val summary = StringBuilder()

        if (targetDate != null) {
            summary.append("DAILY SNAPSHOT FOR $targetDate:\n")
            heartHist.find { it.first == targetDate }?.let { summary.append("- Avg HR: ${it.second} bpm\n") }
            sleepHist.find { it.first == targetDate }?.let { summary.append("- Sleep: ${formatSleep(it.second)} \n") }
            calHist.find { it.first == targetDate }?.let { summary.append("- Active Energy: ${it.second} kcal\n") }
            hrvHist.find { it.first == targetDate }?.let { summary.append("- HRV (RMSSD): ${it.second.toInt()} ms\n") }
            spikeHistory.find { it.date == targetDate }?.let {
                summary.append("- HR Spikes: ${it.spikeCount} events | Max Delta: +${it.maxDelta} bpm | Range: ${it.baseline}-${it.max} bpm\n")
            }
            return summary.toString().trim()
        }

        // ── SECTION 1: Orthostatic spike report (most important for POTS) ────
        if (spikeHistory.isNotEmpty()) {
            val spikeTitle = if (last30DaysOnly) "ORTHOSTATIC HEART RATE SPIKE REPORT (Last 30 Days)" else "ORTHOSTATIC HEART RATE SPIKE REPORT (Full History - Last 180 Days)"
            summary.append("$spikeTitle:\n")
            summary.append("NOTE: Heart rate spikes ≥30 bpm above resting baseline are flagged as orthostatic events.\n")
            summary.append("Format: Date | Avg | Max | Resting Baseline (p10) | Events >100bpm | Largest Spike | Details\n")
            spikeHistory.take(if (last30DaysOnly) 15 else 180).forEach { d ->
                summary.append("- ${formatReportDate(d.date)}: Average: ${d.avg} bpm | Max: ${d.max} bpm | Baseline: ${d.baseline} bpm")
                summary.append(" | Active Spike: ${d.baseline} bpm TO ${d.max} bpm (Delta jump of +${d.maxDelta}) | Count: ${d.spikeCount}")
                if (d.eventsList.isNotEmpty()) {
                    val details = d.eventsList.joinToString(", ") { "${formatSleep(it.durationMins)} peak @${it.peakBpm}" }
                    summary.append(" | durations: [$details]")
                }
                if (d.maxDelta >= 30) summary.append(" ⚠️ Orthostatic threshold met")
                summary.append("\n")
            }
            summary.append("\n")
        }

        // ── SECTION 2: Longer-range daily data (sleep, calories, avg HR, HRV) ─────
        val dailyMap = mutableMapOf<String, DailyBiometricData>()
        val cutOffDate = java.time.LocalDate.now().minusDays(daysLimit.toLong()).toString()
        heartHist.filter { it.first >= cutOffDate }.take(daysLimit).forEach { (date, value) ->
            val current = dailyMap[date] ?: DailyBiometricData()
            dailyMap[date] = current.copy(hr = value)
        }
        if (sleepWithDeepHist.isNotEmpty()) {
            sleepWithDeepHist.filter { it.date >= cutOffDate }.take(daysLimit).forEach { s ->
                val current = dailyMap[s.date] ?: DailyBiometricData()
                dailyMap[s.date] = current.copy(sleep = s.minutesAsleep, deepSleep = s.deepMinutes)
            }
        } else {
            sleepHist.filter { it.first >= cutOffDate }.take(daysLimit).forEach { (date, value) ->
                val current = dailyMap[date] ?: DailyBiometricData()
                dailyMap[date] = current.copy(sleep = value)
            }
        }
        calHist.filter { it.first >= cutOffDate }.take(daysLimit).forEach { (date, value) ->
            val current = dailyMap[date] ?: DailyBiometricData()
            dailyMap[date] = current.copy(cal = value)
        }
        hrvHist.filter { it.first >= cutOffDate }.take(daysLimit).forEach { (date, value) ->
            val current = dailyMap[date] ?: DailyBiometricData()
            dailyMap[date] = current.copy(hrv = value.toInt())
        }
        spikeHistory.filter { it.date >= cutOffDate }.take(daysLimit).forEach { s ->
            val current = dailyMap[s.date] ?: DailyBiometricData()
            dailyMap[s.date] = current.copy(spikes = s.spikeCount)
        }

        val sortedDates = dailyMap.keys.sortedDescending()
        val historyTitle = if (last30DaysOnly) "DETAILED DAILY HISTORY (Last 30 Days)" else "DETAILED DAILY HISTORY (Full History - Last 180 Days)"
        summary.append("$historyTitle:\n")
        summary.append("Format: Date | Avg HR | Sleep | Deep Sleep | Calories | HRV | HR Spikes\n")
        sortedDates.forEach { date ->
            val data = dailyMap[date]!!
            summary.append("- $date: ")
            summary.append(if (data.hr != null) "${data.hr} bpm" else "N/A")
            summary.append(" | ")
            summary.append(if (data.sleep != null) formatSleep(data.sleep) else "N/A")
            summary.append(" | ")
            summary.append(if (data.deepSleep != null) formatSleep(data.deepSleep) else "N/A")
            summary.append(" | ")
            summary.append(if (data.cal != null) "${data.cal} kcal" else "N/A")
            summary.append(" | ")
            summary.append(if (data.hrv != null) "${data.hrv} ms" else "N/A")
            summary.append(" | ")
            summary.append(if (data.spikes != null) "${data.spikes} spikes" else "N/A")
            summary.append("\n")
        }

        if (heartHist.isNotEmpty()) {
            val avgThis = heartHist.take(30).map { it.second }.let { if (it.isNotEmpty()) it.average().toInt() else 0 }
            val avg3 = heartHist.drop(30).take(60).map { it.second }.let { if (it.isNotEmpty()) it.average().toInt() else 0 }
            val avg6 = heartHist.drop(90).take(90).map { it.second }.let { if (it.isNotEmpty()) it.average().toInt() else 0 }
            
            summary.append("\nOVERALL STATISTICAL TRENDS (Last 6 Months):\n")
            summary.append("AI CRITICAL INSTRUCTION: If any 'Sample Count' or 'ID' similar numbers (e.g. 45196, 6464, 6182) appear in the raw logs above, YOU MUST EXCLUDE THEM. ONLY report the averages provided in this section.\n")
            summary.append("- Avg Monthly HR: Current: $avgThis bpm | 3rd Mo: $avg3 bpm | 6th Mo: $avg6 bpm\n")
        }

        if (spikeHistory.isNotEmpty()) {
            val avgSpikes = spikeHistory.map { it.spikeCount }.average()
            val avgDelta = spikeHistory.map { it.maxDelta }.average().toInt()
            val worstDay = spikeHistory.maxByOrNull { it.maxDelta }
            val statsTitle = if (last30DaysOnly) "ORTHOSTATIC SPIKE SUMMARY (Last 30 Days)" else "ORTHOSTATIC SPIKE SUMMARY (Full History - Last 180 Days)"
            summary.append("\n$statsTitle:\n")
            summary.append("- Avg daily events (>100 bpm): ${"%,.1f".format(avgSpikes)}\n")
            summary.append("- Avg max jump: +${avgDelta} bpm\n")
            if (worstDay != null) {
                summary.append("- Worst day: ${formatReportDate(worstDay.date)} — Jumped from ${worstDay.baseline} bpm TO ${worstDay.max} bpm total (+${worstDay.maxDelta}), ${worstDay.spikeCount} total events\n")
            }
        }
        
        summary.append("\nAI DATA INTEGRITY NOTE: Ignore any internal log IDs or large numerical counts. Only report the calculated BPM ranges provided above. If a value exceeds 300 bpm, it is a data artifact and MUST be ignored.")

        return summary.toString().trim()
    }

    private fun formatReportDate(dateStr: String): String {
        return try {
            val sdf1 = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
            val sdf2 = java.text.SimpleDateFormat("yyyyMMdd", java.util.Locale.US)
            val sdfOut = java.text.SimpleDateFormat("MMMM d, yyyy", java.util.Locale.US)
            val date = try {
                sdf1.parse(dateStr)
            } catch (e: Exception) {
                sdf2.parse(dateStr)
            }
            sdfOut.format(date ?: return dateStr)
        } catch (e: Exception) {
            dateStr
        }
    }

    /**
     * Calculates the scientific "Body Load Index" based on the Cup Load Blueprint.
     * Weights: 35% HRV, 30% Sleep, 20% Activity, 10% RHR, 5% Subjective (Tabs).
     */
    suspend fun getBodyLoad(allCategories: List<Category>, dateStr: String? = null): Result<BodyLoadResponse> {
        val today = java.time.LocalDate.now().toString()
        val targetDateStr = dateStr ?: today
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

        // Enforce AI lock: Only today and yesterday are allowed to call the AI or get fresh recalculation
        val isTodayOrYesterday = try {
            val targetDate = java.time.LocalDate.parse(targetDateStr)
            val todayDate = java.time.LocalDate.now()
            targetDate.isEqual(todayDate) || targetDate.isEqual(todayDate.minusDays(1))
        } catch (e: Exception) {
            true // default to allowing calculation if parsing fails
        }

        // ── 1. Fetch Biometrics ──
        val heartJson = preferences.historicalHeartRate.first()
        val heartHist = try {
            if (heartJson.isNotBlank()) json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(heartJson).map { it.date to it.value }
            else if (healthConnectManager.hasAllPermissions()) healthConnectManager.readHistoricalHeartRate(180)
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val sleepJson = preferences.historicalSleep.first()
        val sleepHist = try {
            if (sleepJson.isNotBlank()) json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(sleepJson).map { it.date to it.value }
            else if (healthConnectManager.hasAllPermissions()) healthConnectManager.readHistoricalSleep(180)
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val calJson = preferences.historicalCalories.first()
        val calHist = try {
            if (calJson.isNotBlank()) json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(calJson).map { it.date to it.value }
            else if (healthConnectManager.hasAllPermissions()) healthConnectManager.readHistoricalCalories(180)
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val dataDateStr = try {
            java.time.LocalDate.parse(targetDateStr).minusDays(1).toString()
        } catch (e: Exception) {
            targetDateStr
        }

        val sleepMins = sleepHist.find { it.first == dataDateStr }?.second ?: 0
        val calVal = calHist.find { it.first == dataDateStr }?.second ?: 0

        val insightsStr = preferences.aiInsights.first()
        if (insightsStr.isNotBlank()) {
            val insights = try {
                json.decodeFromString<List<com.notel.notel.data.local.entity.AiInsight>>(insightsStr)
            } catch (e: Exception) { emptyList() }
            
            val targetLocalDate = try {
                java.time.LocalDate.parse(targetDateStr)
            } catch (e: Exception) {
                java.time.LocalDate.now()
            }
            val startOfDay = targetLocalDate.atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()

            val cachedInsight = insights.find { it.type == "BodyLoad" && isSameDay(it.timestamp, startOfDay) }
            if (cachedInsight != null) {
                val text = cachedInsight.text
                val scoreRegex = """Cup %:\s*(\d+)""".toRegex()
                val factorsRegex = """Factors:\s*([^\n|]*)""".toRegex()
                val adviceRegex = """Advice:\s*(.*)""".toRegex()
                
                val cachedScore = scoreRegex.find(text)?.groupValues?.get(1)?.toIntOrNull()
                val cachedFactors = factorsRegex.find(text)?.groupValues?.get(1)?.split(",")?.map { it.trim() }?.filter { it.isNotBlank() } ?: emptyList()
                val cachedAdvice = adviceRegex.find(text)?.groupValues?.get(1)?.trim() ?: ""
                
                // Recalculate if it's today/yesterday, we now have real sleep data, but the cache has 0% or no sleep factor.
                val hasCachedSleep = cachedFactors.any { it.startsWith("Sleep") }
                val isCachedSleepZero = cachedFactors.any { it.startsWith("Sleep") && it.contains("0%") }
                val hasNewSleepData = isTodayOrYesterday && sleepMins > 0 && (!hasCachedSleep || isCachedSleepZero)

                if (cachedScore != null && !hasNewSleepData) {
                    return Result.success(
                        BodyLoadResponse(
                            score = cachedScore,
                            factors = cachedFactors,
                            advice = cachedAdvice,
                            subjectiveImpact = 0.0
                        )
                    )
                }
            }
        }

        // If daily cup updates are disabled and we don't have a cached score, return an empty/disabled response to avoid AI call
        if (!preferences.dailyCupUpdatesEnabled.first()) {
            return Result.success(
                BodyLoadResponse(
                    score = -1,
                    factors = emptyList(),
                    advice = "Daily Cup Updates are disabled in settings.",
                    subjectiveImpact = 0.0
                )
            )
        }
        
        val todayAwake = preferences.todayAwakeAvgHr.first()
        val rawHrVal = if (dataDateStr == today && todayAwake > 0) {
            todayAwake
        } else {
            heartHist.find { it.first == dataDateStr }?.second ?: 0
        }
        val hrVal = if (rawHrVal <= 0) 70 else rawHrVal

        // ── 2. Calculate Rules-Based Loads ──
        
        // A. Sleep Load (40%)
        val sleepLoad = when {
            sleepMins >= 480 -> 0.0
            sleepMins >= 450 -> 10.0 + 20.0 * (480.0 - sleepMins) / 30.0  // 7.5 to 8 hours: 10% to 30% load
            sleepMins >= 420 -> 30.0 + 30.0 * (450.0 - sleepMins) / 30.0  // 7 to 7.5 hours: 30% to 60% load
            sleepMins >= 360 -> 60.0 + 25.0 * (420.0 - sleepMins) / 60.0  // 6 to 7 hours: 60% to 85% load
            else -> (85.0 + 15.0 * (360.0 - sleepMins) / 60.0).coerceAtMost(100.0) // < 6 hours: 85% to 100% load
        }

        // B. Active Calorie Load (25%)
        val calorieLoad = when {
            calVal < 1800 -> 5.0 + 10.0 * (calVal.toDouble() / 1800.0)
            calVal <= 2800 -> 15.0 + 15.0 * ((calVal - 1800).toDouble() / 1000.0)
            else -> (30.0 + 70.0 * ((calVal - 2800).toDouble() / 700.0)).coerceAtMost(100.0)
        }

        // C. Heart Rate Load (30%)
        val heartRateLoad = when {
            hrVal <= 0 -> 0.0
            hrVal in 60..73 -> 10.0 * (hrVal - 60).toDouble() / 13.0
            hrVal in 74..85 -> 10.0 + 35.0 * (hrVal - 73).toDouble() / 12.0
            hrVal > 85 -> (45.0 + 55.0 * (hrVal - 85).toDouble() / 15.0).coerceAtMost(100.0)
            else -> (25.0 * (60 - hrVal).toDouble() / 15.0).coerceAtMost(25.0)
        }

        // ── 3. Calculate Subjective Load (10%) ──
        val targetLocalDate = try {
            java.time.LocalDate.parse(targetDateStr)
        } catch (e: Exception) {
            java.time.LocalDate.now()
        }
        val startOfDay = targetLocalDate.atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        val endOfDay = startOfDay + (24 * 60 * 60 * 1000L) - 1
        
        val dataLocalDate = try {
            java.time.LocalDate.parse(dataDateStr)
        } catch (e: Exception) {
            java.time.LocalDate.now().minusDays(1)
        }
        val dataStartOfDay = dataLocalDate.atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        val dataEndOfDay = dataStartOfDay + (24 * 60 * 60 * 1000L) - 1
        
        val dailyEntries = logEntryDao.getRecentEntriesInRange(dataStartOfDay, dataEndOfDay)
        val jotsContext = logEntryDao.getRecentEntriesBefore(dataEndOfDay, 5)
        
        var subjectiveLoad = 0.0
        var subjectiveReason = ""

        if (jotsContext.isNotEmpty()) {
            try {
                val prompt = """
                    You are a health analysis helper. Read the user's last 5 journal entries (Tabs) leading up to the target day (which ends at timestamp $dataEndOfDay) and evaluate their subjective strain (stress, pain, headaches, insomnia, symptoms, mental fatigue) up to this date.
                    Consider the timing and recency of the Tabs.
                    Determine the subjective allostatic load percentage on a scale from 0% (perfect, relaxed, symptom-free) to 100% (extreme panic, severe pain, severe symptom flare-up, or extreme exhaustion).
                    
                    Example: "had a headache and had a hard time falling asleep" should be rated around 70-80%.
                    
                    You MUST return ONLY a valid JSON object in this exact format:
                    {"impact": <number between 0 and 100>, "reasoning": "<1-sentence explanation>"}
                """.trimIndent()

                val catMap = allCategories.associate { it.id to it.name }
                val response = geminiService.getAdvice(jotsContext, catMap, userContext = prompt)
                
                response.onSuccess { text ->
                    val cleanText = text.trim()
                    val impactRegex = """\"impact\"\s*:\s*(\d+)""".toRegex()
                    val reasoningRegex = """\"reasoning\"\s*:\s*\"([^\"]*)\"""".toRegex()
                    
                    subjectiveLoad = impactRegex.find(cleanText)?.groupValues?.get(1)?.toDoubleOrNull() ?: 0.0
                    subjectiveReason = reasoningRegex.find(cleanText)?.groupValues?.get(1) ?: ""
                }
            } catch (e: Exception) {
                // Fallback to deterministic below
            }
            
            // Offline/Fail Fallback OR if AI returned 0 but there is text
            if (subjectiveLoad == 0.0) {
                var scoreSum = 0.0
                val strainKeywords = listOf(
                    "headache", "pain", "migraine", "nausea", "fatigue", "tired", "stress", 
                    "anxiety", "flare", "crash", "hurt", "bad", "insomnia", "awake", "sleep", 
                    "symptom", "dizzy", "pots", "mcas", "ache", "sore", "hard time"
                )
                jotsContext.forEach { entry ->
                    val text = entry.body.lowercase() + " " + entry.manualText.lowercase()
                    if (entry.categoryId == 1) {
                        scoreSum += 25.0 // Direct Symptoms category
                    } else if (strainKeywords.any { text.contains(it) }) {
                        scoreSum += 25.0 // Keyword matched strain
                    }
                }
                subjectiveLoad = scoreSum.coerceAtMost(100.0)
                subjectiveReason = "Determined via logged symptom keywords."
            }
        }

        // ── 4. Calculate Final Weighted Score (Rescaling gracefully for missing data) ──
        var totalWeight = 0.0
        var weightedLoadSum = 0.0
        
        val hasTabs = jotsContext.isNotEmpty()
        
        // Define weights dynamically: if jots exist, AI subjective load is highly weighted at 40%
        val sleepWeight = if (hasTabs) 0.30 else 0.40
        val calWeight = if (hasTabs) 0.10 else 0.20
        val hrWeight = if (hasTabs) 0.20 else 0.40
        val subjectiveWeight = if (hasTabs) 0.40 else 0.0
        
        if (sleepMins > 0) {
            weightedLoadSum += sleepLoad * sleepWeight
            totalWeight += sleepWeight
        }
        if (calVal > 0) {
            weightedLoadSum += calorieLoad * calWeight
            totalWeight += calWeight
        }
        if (hrVal > 0) {
            weightedLoadSum += heartRateLoad * hrWeight
            totalWeight += hrWeight
        }
        if (hasTabs) {
            weightedLoadSum += subjectiveLoad * subjectiveWeight
            totalWeight += subjectiveWeight
        }
        
        val finalScore = if (totalWeight > 0.0) {
            val rawWeightedLoad = weightedLoadSum / totalWeight
            // Apply a baseline floor of 15% for a perfect body, scaling up to 100%
            Math.round(15.0 + (rawWeightedLoad * 0.85)).toInt()
        } else {
            15 // Default to baseline healthy load if no biometric data exists
        }

        // ── 5. Generate Factors Breakdown & Custom Advice ──
        val factors = mutableListOf<String>()
        if (sleepMins > 0) factors.add("Sleep (${sleepLoad.toInt()}%)")
        if (calVal > 0) factors.add("Active Calories (${calorieLoad.toInt()}%)")
        if (hrVal > 0) factors.add("Heart Rate (${heartRateLoad.toInt()}%)")
        if (hasTabs) factors.add("Subjective (${subjectiveLoad.toInt()}%)")

        val adviceList = mutableListOf<String>()
        if (sleepMins in 1..449) {
            adviceList.add("Sleep was under 7.5 hours (${formatSleep(sleepMins)}). Prioritize deep recovery and rest today.")
        }
        if (calVal > 2800) {
            adviceList.add("High physical exertion detected ($calVal kcal). Minimize strenuous workloads to prevent flare-ups.")
        }
        if (hrVal > 80) {
            adviceList.add("Average heart rate was elevated ($hrVal bpm). Keep hydration high and reduce physical triggers.")
        }
        if (subjectiveLoad > 50.0) {
            adviceList.add("Subjective strain is elevated. Take some time for self-care and mental decompression.")
        }
        
        val finalAdvice = if (adviceList.isNotEmpty()) {
            adviceList.joinToString(" ")
        } else {
            "Your biometric markers are looking great. Maintain your baseline and stay balanced!"
        }

        // Save BodyLoad as an insight so the week summary gets it!
        val bodyLoadText = "Cup %: $finalScore | Factors: ${factors.joinToString(", ")}"
        saveAiInsight(bodyLoadText, "BodyLoad", startOfDay)

        return Result.success(
            BodyLoadResponse(
                score = finalScore,
                factors = factors,
                advice = finalAdvice,
                subjectiveImpact = subjectiveLoad
            )
        )
    }
    
    private fun formatSleep(mins: Int): String {
        val h = mins / 60
        val m = mins % 60
        return when {
            h > 0 && m > 0 -> "${h}h ${m}m"
            h > 0 -> "${h}h"
            else -> "${m}m"
        }
    }

    private fun sigmoidScore(z: Double, k: Double = 1.2): Double {
        return 0.0
    }

    /**
     * Entry point for Google Assistant notes.
     * Cleans text (removes extras like "um", "uh") and classifies into best category.
     */
    suspend fun handleVoiceNote(rawText: String, useAI: Boolean = true): Result<String> {
        val categories = categoryRepository.getAllCategories().first()
        val catMap = categories.associate { it.id to it.name }
        
        if (!useAI) {
            // Save Raw: Skip AI and put in General category (ID 7)
            insertEntry(
                LogEntry(
                    categoryId = 7, 
                    body = rawText,
                    manualText = "", // No longer storing redundant manual text
                    source = "Voice Raw"
                )
            )
            return Result.success("Note saved as raw.")
        }
        
        // Clean with AI (Gemini)
        return geminiService.classifyAndCleanNote(rawText, catMap).fold(
            onSuccess = { response ->
                insertEntry(
                    LogEntry(
                        categoryId = response.categoryId,
                        body = response.cleanedText,
                        manualText = "", // No longer storing redundant manual text
                        source = "Voice AI"
                    )
                )
                Result.success("Note saved to ${catMap[response.categoryId] ?: "General"}")
            },
            onFailure = { 
                // Fallback to General (ID 7) if AI fails
                insertEntry(
                    LogEntry(
                        categoryId = 7, 
                        body = rawText,
                        manualText = "", // No longer storing redundant manual text
                        source = "Voice AI (Fallback)"
                    )
                )
                Result.success("Note saved to General")
            }
        )
    }

    /**
     * Entry point for coach-suggested approved notes.
     * Keeps the text EXACTLY as-is, categorizes it, and saves it.
     */
    suspend fun handleCoachNote(noteText: String): Result<String> {
        val categories = categoryRepository.getAllCategories().first()
        val catMap = categories.associate { it.id to it.name }
        
        // Use Gemini to classify the note without cleaning/modifying the text
        return geminiService.classifyCoachNoteCategory(noteText, catMap).fold(
            onSuccess = { categoryId ->
                insertEntry(
                    LogEntry(
                        categoryId = categoryId,
                        body = noteText,
                        manualText = "",
                        source = "Tabs Coach"
                    )
                )
                Result.success("Note saved to ${catMap[categoryId] ?: "General"}")
            },
            onFailure = { 
                // Fallback to General (ID 7) if AI classification fails
                insertEntry(
                    LogEntry(
                        categoryId = 7, 
                        body = noteText,
                        manualText = "",
                        source = "Tabs Coach"
                    )
                )
                Result.success("Note saved to General")
            }
        )
    }

    private fun isSameDay(t1: Long, t2: Long): Boolean {
        val d1 = java.time.Instant.ofEpochMilli(t1).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        val d2 = java.time.Instant.ofEpochMilli(t2).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        return d1 == d2
    }

    fun getAllInsightsWithEntryAndCategory(): Flow<List<com.notel.notel.data.local.entity.AiInsightWithEntryAndCategory>> {
        return db.aiInsightDao().getAllInsightsWithEntryAndCategory()
    }

    suspend fun deleteAccountData(): Result<Unit> {
        return try {
            // 1. Delete account from cloud server
            val response = tabsApi.deleteAccount()
            if (!response.isSuccessful) {
                return Result.failure(Exception(response.errorBody()?.string() ?: "Cloud delete failed"))
            }

            // 2. Clear all local Knowledge Documents files from disk
            clearAllDocuments()

            // 3. Clear Room database tables
            db.clearAllTables()

            // 4. Reset sync preferences and session tokens
            preferences.clearCredentials()

            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
