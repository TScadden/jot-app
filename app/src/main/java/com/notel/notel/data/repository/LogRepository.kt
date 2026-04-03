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
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import com.notel.notel.data.local.entity.AiInsight
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LogRepository @Inject constructor(
    private val logEntryDao: LogEntryDao,
    private val geminiService: GeminiService,
    private val preferences: NotelPreferences,
    private val healthConnectManager: HealthConnectManager,
    private val syncManager: SyncManager,
    private val categoryRepository: CategoryRepository,
    private val habitRepository: HabitRepository,
    private val lifecycleTracker: com.notel.notel.util.AppLifecycleTracker,
    private val jotApi: com.notel.notel.data.remote.JotApi,
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: android.content.Context
) {
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

    private val _processError = MutableStateFlow<String?>(null)
    val processError = _processError.asStateFlow()

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
    fun generateProfessionalReportAsync(allCategories: List<Category>, reportGenerator: com.notel.notel.util.ReportGenerator) {
        if (_isGeneratingReport.value) return
        _isGeneratingReport.value = true
        GlobalScope.launch {
            try {
                val entries = logEntryDao.getAllEntries().first()
                val file = reportGenerator.generateReport(entries, allCategories)
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

    suspend fun insertEntry(entry: LogEntry): Long {
        val id = logEntryDao.insertEntry(entry)
        triggerSync()
        return id
    }

    suspend fun getRecentEntriesAll(limit: Int = 10): List<LogEntry> =
        logEntryDao.getRecentEntriesAll(limit)

    suspend fun updateEntry(entry: LogEntry) {
        logEntryDao.updateEntry(entry)
        triggerSync()
    }

    suspend fun deleteEntry(entry: LogEntry) {
        try {
            // 1. Local Delete
            logEntryDao.deleteEntry(entry)
            
            // 2. Cloud Delete (so it doesn't come back on the next sync)
            jotApi.deleteEntry(entry.id)
            
            // 3. Trigger refresh
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

    suspend fun getEntryById(id: Long): LogEntry? = logEntryDao.getEntryById(id)

    /**
     * Fetches AI chip suggestions for the given [category].
     * Pulls recent history from Room for context, then calls Gemini.
     */
    suspend fun getChipSuggestions(category: Category): Result<List<String>> {
        val isUnlimited = preferences.isUnlimited.first()
        val balance = preferences.userBalance.first()
        if (!isUnlimited && balance < 0.01f) return Result.failure(IllegalStateException("Insufficient credits. Please top up in Settings."))

        val recent = logEntryDao.getRecentEntries(category.id, limit = 20)
        val context = getEnrichedUserContext()
        val kb = getEnrichedKnowledgeBase()
        
        return geminiService.getSuggestions(category, recent, userContext = context, knowledgeBase = kb).onSuccess {
            preferences.deductBalance(0.01f)
        }
    }

    suspend fun getSmartCategorySuggestion(existingCategories: List<String>): Result<com.notel.notel.data.remote.SmartCategorySuggestion?> {
        val isUnlimited = preferences.isUnlimited.first()
        val balance = preferences.userBalance.first()
        if (!isUnlimited && balance < 0.01f) return Result.success(null) // Silently fail if low on credits

        val recent = logEntryDao.getRecentEntriesAll(limit = 50)
        val context = getEnrichedUserContext()
        
        return geminiService.getSmartCategorySuggestion(recent, existingCategories).onSuccess {
            preferences.deductBalance(0.01f)
        }
    }

    private suspend fun getEnrichedUserContext(): String {
        val baseContext = preferences.userContext.first()
        val countersJson = preferences.eventCounters.first()
        if (countersJson.isBlank() || countersJson == "[]") return baseContext
        
        var counterContext = ""
        try {
            val counters = kotlinx.serialization.json.Json.decodeFromString<List<com.notel.notel.ui.viewmodel.EventCounterDto>>(countersJson)
            if (counters.isNotEmpty()) {
                val sb = java.lang.StringBuilder("\n\nActive Event Counters (IMPORTANT CONTEXT):\n")
                counters.forEach { counter ->
                    val diffMillis = counter.targetDate - System.currentTimeMillis()
                    var isUp = counter.isUp
                    var finalDiffMillis = diffMillis
                    
                    if (!isUp && diffMillis < 0 && counter.autoUp) {
                        isUp = true
                        finalDiffMillis = System.currentTimeMillis() - counter.targetDate
                    } else if (isUp) {
                        finalDiffMillis = System.currentTimeMillis() - counter.targetDate
                    }
                    
                    if (isUp || diffMillis >= 0) {
                        val daysRemaining = java.util.concurrent.TimeUnit.MILLISECONDS.toDays(Math.abs(finalDiffMillis))
                        val direction = if (isUp) "since" else "until"
                        sb.append("- ${counter.name}: ${daysRemaining} days ${direction}\n")
                    }
                }
                counterContext = sb.toString()
            }
        } catch (e: Exception) {
            // ignore
        }
        
        return if (counterContext.isNotEmpty()) {
            "$baseContext$counterContext"
        } else {
            baseContext
        }
    }

    private suspend fun getEnrichedKnowledgeBase(): String {
        val kb = preferences.knowledgeBase.first()
        val proUpdates = preferences.professionalUpdates.first()
        if (proUpdates.isBlank()) return kb
        return if (kb.isBlank()) "PROFESSIONAL INSTRUCTIONS:\n$proUpdates" else "$kb\n\nPROFESSIONAL INSTRUCTIONS:\n$proUpdates"
    }

    private suspend fun getHabitDataSummary(): String {
        val habits = habitRepository.habits.first()
        if (habits.isEmpty()) return ""
        val today = java.time.LocalDate.now()
        val sb = StringBuilder()
        
        val allLogsTotallyEmpty = habits.all { it.logs.isEmpty() }
        
        sb.append("HABIT TRACKER LOGS (Chronological for Correlation):\n")
        
        if (allLogsTotallyEmpty) {
            sb.append("- [STREAK DATA UNAVAILABLE / ALL HISTORICAL HABIT LOGS RECENTLY CLEARED BY USER]\n")
            sb.append("AI CRITICAL INSTRUCTION: The user has explicitly RESET their habit data. You MUST ignore any habit streaks or completion history from previous sessions or 'Past Insights'. Every current habit streak is 0 days. Report that habit tracking has been reset.\n")
        } else {
            sb.append("Format: Date: [Habits completed on this day]\n")
            var hasAnyLog = false
            // Show chronological map of the last 15 days of habits for context-aware symptom correlation
            for (i in 0..14) {
                val checkDay = today.minusDays(i.toLong())
                val dateStr = checkDay.format(java.time.format.DateTimeFormatter.ISO_LOCAL_DATE)
                val completed = habits.filter { it.logs.contains(dateStr) }.map { it.title }
                if (completed.isNotEmpty()) {
                    hasAnyLog = true
                    sb.append("- $dateStr: ${completed.joinToString(", ")}\n")
                }
            }
            if (!hasAnyLog) {
                sb.append("- No habits logged in the last 15 days, but historical logs exist.\n")
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
        val balance = preferences.userBalance.first()
        if (!isUnlimited && balance < 0.01f) return Result.failure(IllegalStateException("Insufficient credits. Please top up in Settings."))

        val result = geminiService.getAdvice(recent, catMap, userContext = context, knowledgeBase = kb, pastInsights = pastInsights, fitbitData = fitbitData, habitData = habitData)
        result.onSuccess { text ->
            preferences.deductBalance(0.01f)
            saveAiInsight(text, "Advice")
        }
        return result
    }

    suspend fun getMedicalReportSummary(allCategories: List<Category>): Result<String> {
        val recent = logEntryDao.getRecentEntriesAll(limit = 300)
        
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
        
        val fitbitData = getFitbitDataSummary()
        val habitData = getHabitDataSummary()
        
        val isUnlimited = preferences.isUnlimited.first()
        val balance = preferences.userBalance.first()
        if (!isUnlimited && balance < 0.05f) return Result.failure(IllegalStateException("Insufficient credits ($0.05 required). Please top up in Settings."))

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
                bodyLoadHistory = bodyLoadHistory
            )
            
            if (finalResult.isSuccess) break
            
            attempts--
            if (attempts > 0) kotlinx.coroutines.delay(1000L) // Wait 1s and try again
        }

        finalResult.onSuccess { text ->
            preferences.deductBalance(0.05f)
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

        val isUnlimited = preferences.isUnlimited.first()
        val balance = preferences.userBalance.first()
        if (!isUnlimited && balance < 0.05f) return Result.failure(IllegalStateException("Insufficient credits ($0.05 required). Please top up in Settings."))

        val result = geminiService.getWeeklyRecap(recent, catMap, userContext = context, knowledgeBase = kb, fitbitData = fitbitData, habitData = habitData)
        result.onSuccess { text ->
            preferences.deductBalance(0.05f)
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

        val isUnlimited = preferences.isUnlimited.first()
        val balance = preferences.userBalance.first()
        if (!isUnlimited && balance < 0.10f) return Result.failure(IllegalStateException("Insufficient credits ($0.10 required). Please top up in Settings."))

        val result = geminiService.getDeepResearch(recent, catMap, userContext = context, knowledgeBase = kb, pastInsights = pastInsights, fitbitData = fitbitData, habitData = habitData)
        result.onSuccess { text ->
            preferences.deductBalance(0.10f)
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

        val isUnlimited = preferences.isUnlimited.first()
        val balance = preferences.userBalance.first()
        if (!isUnlimited && balance < 0.05f) return Result.failure(IllegalStateException("Insufficient credits ($0.05 required). Please top up in Settings."))

        val result = geminiService.getDocumentComparison(recent, catMap, userContext = context, knowledgeBase = kb, pastInsights = pastInsights, fitbitData = fitbitData, habitData = habitData)
        result.onSuccess { text ->
            preferences.deductBalance(0.05f)
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
    
    suspend fun saveAiInsight(text: String, type: String) {
        val insightsStr = preferences.aiInsights.first()
        val insights: MutableList<AiInsight> = try {
            if (insightsStr.isNotBlank()) Json.decodeFromString<MutableList<AiInsight>>(insightsStr) else mutableListOf()
        } catch(e: Exception) { mutableListOf() }
        insights.add(0, AiInsight(java.util.UUID.randomUUID().toString(), text, System.currentTimeMillis(), type))
        preferences.setAiInsights(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(AiInsight.serializer()), insights.take(20))) // Keep last 20
    }

    suspend fun ingestDocumentFile(fileName: String, mimeType: String, base64Data: String): Result<Unit> {
        val isUnlimited = preferences.isUnlimited.first()
        val balance = preferences.userBalance.first()
        if (!isUnlimited && balance < 0.05f) return Result.failure(IllegalStateException("Insufficient credits ($0.05 required). Please top up in Settings."))

        return geminiService.processDocumentFile(mimeType, base64Data).fold(
            onSuccess = { newKnowledge ->
                preferences.deductBalance(0.05f)
                val timestamp = java.text.SimpleDateFormat("MMMM d, yyyy", java.util.Locale.US).format(java.util.Date())
                val entry = "[ADDED $timestamp]\n$newKnowledge"
                val currentKb = preferences.knowledgeBase.first()
                val updatedKb = if (currentKb.isBlank()) entry else "$entry\n\n$currentKb"
                preferences.setKnowledgeBase(updatedKb)
                
                // Track that we processed this file
                val currentFiles = preferences.processedFiles.first()
                val updatedFiles = if (currentFiles.isBlank()) fileName else "$fileName, $currentFiles"
                preferences.setProcessedFiles(updatedFiles)
                
                triggerSync()
                Result.success(Unit)
            },
            onFailure = { Result.failure(it) }
        )
    }

    suspend fun ingestTextNote(title: String, text: String): Result<Unit> {
        val base64 = android.util.Base64.encodeToString(text.toByteArray(), android.util.Base64.NO_WRAP)
        return ingestDocumentFile(title, "text/plain", base64)
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

    private suspend fun getFitbitDataSummary(): String {
        val hasHealthConnect = healthConnectManager.hasAllPermissions()
        val fitbitToken = preferences.fitbitToken.first()
        if (!hasHealthConnect && fitbitToken.isBlank()) return ""

        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

        // ── Spike-aware heart rate (POTS/MCAS critical) ───────────────────────
        val spikesJson = preferences.historicalHrSpikes.first()
        val spikeHistory: List<DailyHeartRateSummary> = if (spikesJson.isNotBlank()) {
            try { json.decodeFromString(spikesJson) } catch (e: Exception) { emptyList() }
        } else if (hasHealthConnect) {
            // Fresh fetch from Health Connect — raw samples, last 30 days
            val fresh = healthConnectManager.readHistoricalHeartRateWithSpikes(30)
            if (fresh.isNotEmpty()) {
                preferences.setHistoricalHrSpikes(kotlinx.serialization.json.Json.encodeToString(
                    kotlinx.serialization.serializer<List<DailyHeartRateSummary>>(), fresh
                ))
            }
            fresh
        } else emptyList()

        // ── Plain daily averages (fallback / longer history) ─────────────────
        val heartJson = preferences.historicalHeartRate.first()
        val heartHist = try {
            if (heartJson.isNotBlank()) json.decodeFromString<List<BiomarkerPoint>>(heartJson).map { it.date to it.value }
            else if (hasHealthConnect) healthConnectManager.readHistoricalHeartRate(180).sortedByDescending { it.first }
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val sleepJson = preferences.historicalSleep.first()
        val sleepHist = try {
            if (sleepJson.isNotBlank()) json.decodeFromString<List<BiomarkerPoint>>(sleepJson).map { it.date to it.value }
            else if (hasHealthConnect) healthConnectManager.readHistoricalSleep(180).sortedByDescending { it.first }
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val calJson = preferences.historicalCalories.first()
        val calHist = try {
            if (calJson.isNotBlank()) json.decodeFromString<List<BiomarkerPoint>>(calJson).map { it.date to it.value }
            else if (hasHealthConnect) healthConnectManager.readHistoricalCalories(180).sortedByDescending { it.first }
            else emptyList()
        } catch (e: Exception) { emptyList() }

        val summary = StringBuilder()

        // ── SECTION 1: Orthostatic spike report (most important for POTS) ────
        if (spikeHistory.isNotEmpty()) {
            summary.append("ORTHOSTATIC HEART RATE SPIKE REPORT (Last 30 Days):\n")
            summary.append("NOTE: Heart rate spikes ≥30 bpm above resting baseline are flagged as orthostatic events.\n")
            summary.append("Format: Date | Avg | Max | Resting Baseline (p10) | Events >100bpm | Largest Spike | Details\n")
            spikeHistory.take(30).forEach { d ->
                summary.append("- ${formatReportDate(d.date)}: Average: ${d.avg} bpm | Max: ${d.max} bpm | Baseline: ${d.baseline} bpm")
                summary.append(" | Active Spike: ${d.baseline} bpm TO ${d.max} bpm (Delta jump of +${d.maxDelta}) | Count: ${d.spikeCount}")
                if (d.eventsList.isNotEmpty()) {
                    val details = d.eventsList.joinToString(", ") { "${it.durationMins}m peak @${it.peakBpm}" }
                    summary.append(" | durations: [$details]")
                }
                if (d.maxDelta >= 30) summary.append(" ⚠️ Orthostatic threshold met")
                summary.append("\n")
            }
            summary.append("\n")
        }

        // ── SECTION 2: Longer-range daily data (sleep, calories, avg HR) ─────
        val dailyMap = mutableMapOf<String, Triple<Int?, Int?, Int?>>()
        val cutOffDate = java.time.LocalDate.now().minusDays(31).toString()
        heartHist.filter { it.first >= cutOffDate }.take(31).forEach { (date, value) ->
            val current = dailyMap[date] ?: Triple(null, null, null)
            dailyMap[date] = current.copy(first = value)
        }
        sleepHist.filter { it.first >= cutOffDate }.take(31).forEach { (date, value) ->
            val current = dailyMap[date] ?: Triple(null, null, null)
            dailyMap[date] = current.copy(second = value)
        }
        calHist.filter { it.first >= cutOffDate }.take(31).forEach { (date, value) ->
            val current = dailyMap[date] ?: Triple(null, null, null)
            dailyMap[date] = current.copy(third = value)
        }

        val sortedDates = dailyMap.keys.sortedDescending()
        summary.append("DETAILED DAILY HISTORY (Last 30 Days):\n")
        summary.append("Format: Date | Avg HR | Sleep | Calories\n")
        sortedDates.forEach { date ->
            val (hr, sleep, cal) = dailyMap[date]!!
            summary.append("- $date: ")
            summary.append(if (hr != null) "$hr bpm" else "N/A")
            summary.append(" | ")
            summary.append(if (sleep != null) "$sleep min" else "N/A")
            summary.append(" | ")
            summary.append(if (cal != null) "$cal kcal" else "N/A")
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
            summary.append("\nORTHOSTATIC SPIKE SUMMARY (Last 30 Days):\n")
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
     * Calculates the "Body Load Index" based on the last 7 days (approx 50 entries)
     * plus Fitbit/Habit data.
     */
    suspend fun getBodyLoad(allCategories: List<Category>): Result<BodyLoadResponse> {
        val isUnlimited = preferences.isUnlimited.first()
        val balance = preferences.userBalance.first()
        if (!isUnlimited && balance < 0.05f) return Result.failure(IllegalStateException("Insufficient credits (0.05 Required)"))

        val recent = logEntryDao.getRecentEntriesAll(limit = 50)
        val catMap = allCategories.associate { it.id to it.name }
        val context = getEnrichedUserContext()
        val kb = getEnrichedKnowledgeBase()
        val fitbitData = getFitbitDataSummary()
        val habitData = getHabitDataSummary()
        val pastInsights = getPastInsightsText()

        return geminiService.getBodyLoad(
            recentEntries = recent,
            categories = catMap,
            userContext = context,
            knowledgeBase = kb,
            fitbitData = fitbitData,
            habitData = habitData,
            pastInsights = pastInsights
        ).onSuccess { res ->
            preferences.deductBalance(0.05f)
            saveAiInsight("Body Load: ${res.score} | Factors: ${res.factors.joinToString(", ")}", "BodyLoad")
        }
    }

    /**
     * Entry point for Google Assistant notes.
     * Cleans text (removes extras like "um", "uh") and classifies into best category.
     */
    suspend fun handleAssistantNote(rawText: String): Result<String> {
        val categories = categoryRepository.getAllCategories().first()
        val catMap = categories.associate { it.id to it.name }
        
        return geminiService.classifyAndCleanNote(rawText, catMap).fold(
            onSuccess = { response ->
                insertEntry(
                    LogEntry(
                        categoryId = response.categoryId,
                        body = response.cleanedText,
                        manualText = response.cleanedText,
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
                        manualText = rawText
                    )
                )
                Result.success("Note saved to General")
            }
        )
    }
}
