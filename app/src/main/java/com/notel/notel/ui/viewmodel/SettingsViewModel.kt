package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import com.notel.notel.data.local.entity.AiInsight
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.service.HrSpikeMonitorService
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import kotlinx.coroutines.flow.first
import com.notel.notel.data.sync.SyncManager

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences,
    private val categoryRepository: CategoryRepository,
    private val reportGenerator: com.notel.notel.util.ReportGenerator,
    val healthConnectManager: HealthConnectManager,
    val billingManager: com.notel.notel.data.billing.BillingManager,
    private val syncManager: SyncManager,
    private val database: com.notel.notel.data.local.NotelDatabase,
    private val habitRepository: com.notel.notel.data.repository.HabitRepository,
    private val jotApi: com.notel.notel.data.remote.JotApi,
    @ApplicationContext private val context: android.content.Context
) : ViewModel() {

    private val _systemLogs = MutableStateFlow<List<SystemLog>>(emptyList())
    val systemLogs = _systemLogs.asStateFlow()

    fun addSystemLog(body: String) {
        val newLog = SystemLog(body, System.currentTimeMillis())
        _systemLogs.update { (listOf(newLog) + it).take(100) }
    }

    init {
        syncManager.setLogCallback { addSystemLog(it) }
        viewModelScope.launch {
            try {
                syncManager.pullAllData()
            } catch (e: Exception) {
                // Ignore silent background pull failures
            }
        }
    }



    val userContext = preferences.userContext
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val lastSyncTime = preferences.lastSyncTime
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0L)

    val knowledgeBase = preferences.knowledgeBase
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val redditSubreddits: StateFlow<List<LinkedSubreddit>> = preferences.redditSubreddits
        .map { json ->
            try {
                if (json.isNotBlank() && json != "[]") Json.decodeFromString<List<LinkedSubreddit>>(json)
                else emptyList()
            } catch (e: Exception) { emptyList() }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val professionalUpdates = preferences.professionalUpdates
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val redditSummaries = preferences.redditSummaries
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val processedFiles = preferences.processedFiles
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val knowledgeDocuments = logRepository.getAllDocuments()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val categories = categoryRepository.getAllCategories()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val aiInsights = preferences.aiInsights
        .map { json ->
            try {
                if (json.isNotBlank()) Json.decodeFromString<List<AiInsight>>(json)
                else emptyList()
            } catch(e: Exception) { emptyList() }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _healthConnectConnected = MutableStateFlow(false)
    val healthConnectConnected = _healthConnectConnected.asStateFlow()

    private val _isRefreshingReddit = MutableStateFlow<String?>(null) // subreddit name currently refreshing
    val isRefreshingReddit = _isRefreshingReddit.asStateFlow()

    private val _redditError = MutableSharedFlow<String>()
    val redditError = _redditError.asSharedFlow()

    private val _redditSynced = MutableSharedFlow<String>()
    val redditSynced = _redditSynced.asSharedFlow()

    private val _isRecovering = MutableStateFlow(false)
    val isRecovering = _isRecovering.asStateFlow()

    private val _isManualSyncing = MutableStateFlow(false)
    val isManualSyncing = _isManualSyncing.asStateFlow()

    // Kept for recoverAccountData compatibility in logout flow
    private val _isSyncing = MutableStateFlow(false)
    val isSyncing = _isSyncing.asStateFlow()

    private val _syncError = MutableSharedFlow<String>()
    val syncError = _syncError.asSharedFlow()

    val showProfessionalCheckIn = combine(
        userContext,
        knowledgeBase,
        logRepository.getAllEntries()
    ) { ctx, kb, logs ->
        val keywords = listOf("doctor", "dr.", "coach", "physician", "therapist", "running", "marathon", "race", "training")
        val lowerCtx = ctx.lowercase()
        val lowerKB = kb.lowercase()
        
        val ctxMatch = keywords.any { lowerCtx.contains(it) }
        val kbMatch = keywords.any { lowerKB.contains(it) }
        val logMatch = logs.any { log -> 
            keywords.any { log.body.lowercase().contains(it) }
        }
        
        ctxMatch || kbMatch || logMatch
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    init {
        checkHealthConnectStatus()
        cleanKnowledgeBase()
        backfillDocumentExtractions()
    }

    /**
     * One-time background pass: for every document that doesn't have cached extracted text yet,
     * read its file and extract it now. Runs on init so text is ready BEFORE the user generates a PDF.
     */
    private fun backfillDocumentExtractions() {
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            val docs = logRepository.getAllDocuments().first()
            val missing = docs.filter { it.extractedText.isNullOrBlank() }
            missing.forEach { doc ->
                logRepository.extractAndCacheDocumentText(doc)
            }
        }
    }

    private fun cleanKnowledgeBase() {
        viewModelScope.launch {
            val kb = preferences.knowledgeBase.first()
            if (kb.contains("[REDDIT r/")) {
                val lines = kb.split("\n\n").filter { !it.contains("[REDDIT r/") }
                preferences.setKnowledgeBase(lines.joinToString("\n\n"))
            }
        }
    }

    fun checkHealthConnectStatus() {
        viewModelScope.launch {
            _healthConnectConnected.value = healthConnectManager.hasAllPermissions()
        }
    }

    val userAge = preferences.userAge.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)
    val userHeight = preferences.userHeight.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0f)
    val userWeight = preferences.userWeight.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0f)
    val userGender = preferences.userGender.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")
    
    val isUnlimited = preferences.isUnlimited
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val autoAiSuggestions = preferences.autoAiSuggestions
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val settingsTutorialSeen: StateFlow<Boolean?> = preferences.settingsTutorialSeen
        .map { it as Boolean? }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val userContextHidden = preferences.userContextHidden
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val bodyLoadRemindersEnabled = preferences.bodyLoadRemindersEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val dailyCupUpdatesEnabled = preferences.dailyCupUpdatesEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val userNickname = preferences.userNickname
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val userTag = preferences.userTag
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val shareDataWithFriends = preferences.shareDataWithFriends
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val hrSpikeAlertsEnabled = preferences.hrSpikeAlertsEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val reportReadyEvent = logRepository.reportReadyEvent
    val aiInsightReadyEvent = logRepository.aiInsightReadyEvent

    fun resetGeneratedReport() {
        logRepository.resetGeneratedReport()
    }

    val spikeThreshold = preferences.spikeThreshold
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 120)

    val hrDeltaEnabled = preferences.hrDeltaEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val spikeDeltaThreshold = preferences.spikeDeltaThreshold
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 30)

    val habitReminderEnabled = preferences.habitReminderEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val projectReminderEnabled = preferences.projectReminderEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    fun markSettingsTutorialSeen() {
        viewModelScope.launch { preferences.setSettingsTutorialSeen(true) }
    }

    fun resetSettingsTutorial() {
        viewModelScope.launch { preferences.setSettingsTutorialSeen(false) }
    }

    private val _isProcessingFile = MutableStateFlow(false)
    val isProcessingFile = _isProcessingFile.asStateFlow()

    val processError = logRepository.processError

    val generatedReport = logRepository.generatedReport

    val isGeneratingReport = logRepository.isGeneratingReport

    val isGeneratingWeeklyRecap = logRepository.isGeneratingWeeklyRecap

    val isGeneratingDeepResearch = logRepository.isGeneratingDeepResearch

    val allLogs = logRepository.getAllEntries().stateIn(
        viewModelScope,
        SharingStarted.Lazily,
        emptyList()
    )

    val billingEvents = billingManager.billingEvents



    fun purchaseCredits(activity: android.app.Activity, productId: String, quantity: Int = 1) {
        billingManager.launchPurchaseFlow(activity, productId, quantity)
    }

    private var pushContextJob: kotlinx.coroutines.Job? = null

    fun saveUserContext(text: String) {
        viewModelScope.launch { 
            preferences.setUserContext(text)
            preferences.setUserContextLastUpdate(System.currentTimeMillis())
            
            // Debounce pushing profile changes to the server by 800ms
            pushContextJob?.cancel()
            pushContextJob = viewModelScope.launch {
                kotlinx.coroutines.delay(800)
                syncManager.pushProfileData()
            }
        }
    }

    fun toggleUserContextHidden() {
        viewModelScope.launch {
            val current = userContextHidden.value
            preferences.setUserContextHidden(!current)
        }
    }

    fun saveUserProfile(age: Int, height: Float, weight: Float, gender: String) {
        viewModelScope.launch {
            preferences.setUserProfileStats(age, height, weight, gender)
            syncManager.pushProfileData()
        }
    }

    private val _isSyncingProfile = MutableStateFlow(false)
    val isSyncingProfile = _isSyncingProfile.asStateFlow()

    fun syncHealthProfile() {
        viewModelScope.launch {
            _isSyncingProfile.value = true
            try {
                var newAge = userAge.value
                var newGender = userGender.value
                var newWeight = userWeight.value
                var newHeight = userHeight.value

                // 1. Try Health Connect first for Weight and Height
                if (healthConnectManager.hasAllPermissions()) {
                    val hcWeight = healthConnectManager.readLatestWeight("today")
                    val hcHeight = healthConnectManager.readLatestHeight()
                    if (hcWeight != null && hcWeight > 0f) newWeight = Math.round(hcWeight).toFloat()
                    if (hcHeight != null && hcHeight > 0f) newHeight = Math.round(hcHeight).toFloat()
                }

                // 2. Try Fitbit Cloud (can provide Age and Gender too)
                val token = preferences.fitbitToken.first()
                if (token.isNotBlank()) {
                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        val request = okhttp3.Request.Builder()
                            .url("https://api.fitbit.com/1/user/-/profile.json")
                            .header("Authorization", "Bearer $token")
                            .build()
                        val client = okhttp3.OkHttpClient()
                        client.newCall(request).execute().use { response ->
                            if (response.isSuccessful) {
                                val body = response.body?.string() ?: ""
                                val jsonParser = Json { ignoreUnknownKeys = true }
                                val root = jsonParser.parseToJsonElement(body).jsonObject
                                val user = root["user"]?.jsonObject
                                
                                val fAge = user?.get("age")?.jsonPrimitive?.intOrNull
                                val fHeight = user?.get("height")?.jsonPrimitive?.floatOrNull
                                val fWeight = user?.get("weight")?.jsonPrimitive?.floatOrNull
                                val fGender = user?.get("gender")?.jsonPrimitive?.content
                                val heightUnit = user?.get("heightUnit")?.jsonPrimitive?.content ?: ""
                                val weightUnit = user?.get("weightUnit")?.jsonPrimitive?.content ?: ""
                                
                                if (fAge != null && fAge > 0) newAge = fAge
                                if (!fGender.isNullOrBlank()) newGender = fGender
                                if (fHeight != null && fHeight > 0f) {
                                    val rawHeight = if (heightUnit.equals("METRIC", ignoreCase = true) || heightUnit.equals("cm", ignoreCase = true)) {
                                        if (fHeight < 100f) fHeight else fHeight / 2.54f
                                    } else if (heightUnit.equals("US", ignoreCase = true) || heightUnit.equals("inches", ignoreCase = true)) {
                                        fHeight
                                    } else {
                                        if (fHeight > 100f) fHeight / 2.54f else fHeight
                                    }
                                    newHeight = Math.round(rawHeight).toFloat()
                                }
                                if (fWeight != null && fWeight > 0f) {
                                    val rawWeight = if (weightUnit.equals("METRIC", ignoreCase = true) || weightUnit.equals("kg", ignoreCase = true)) {
                                        if (fWeight > 140f) fWeight else fWeight * 2.20462f
                                    } else if (weightUnit.equals("US", ignoreCase = true) || weightUnit.equals("lbs", ignoreCase = true)) {
                                        fWeight
                                    } else {
                                        if (fWeight < 130f) fWeight * 2.20462f else fWeight
                                    }
                                    newWeight = Math.round(rawWeight).toFloat()
                                }
                            }
                        }
                    }
                }

                // Combine and save
                if (newAge > 0 || newHeight > 0f || newWeight > 0f || newGender.isNotBlank()) {
                    saveUserProfile(newAge, newHeight, newWeight, newGender)
                }

            } catch (e: Exception) {
                // Ignore sync errors gracefully
            } finally {
                _isSyncingProfile.value = false
            }
        }
    }

    fun ingestFile(uri: android.net.Uri, contentResolver: android.content.ContentResolver) {
        viewModelScope.launch {
            _isProcessingFile.value = true
            logRepository.clearProcessError()
            
            try {
                val fileName = getFileName(uri, contentResolver) ?: "unknown_file"
                val mimeType = contentResolver.getType(uri) ?: "application/pdf"
                val fileBytes = contentResolver.openInputStream(uri)?.use { stream ->
                    stream.readBytes()
                } ?: throw Exception("Could not read file content")
                val base64 = android.util.Base64.encodeToString(fileBytes, android.util.Base64.NO_WRAP)

                logRepository.ingestDocumentFile(fileName, mimeType, base64).onFailure {
                    logRepository.setProcessError(it.message ?: "Failed to process file")
                }
            } catch (e: Exception) {
                logRepository.setProcessError(e.message ?: "An error occurred")
            } finally {
                _isProcessingFile.value = false
            }
        }
    }

    fun processManualTextNote(title: String, body: String) {
        viewModelScope.launch {
            _isProcessingFile.value = true
            logRepository.clearProcessError()
            
            try {
                logRepository.ingestTextNote(title, body).onFailure {
                    logRepository.setProcessError(it.message ?: "Failed to process text note")
                }
            } catch (e: Exception) {
                logRepository.setProcessError(e.message ?: "An error occurred")
            } finally {
                _isProcessingFile.value = false
            }
        }
    }

    fun clearKnowledge() {
        viewModelScope.launch { logRepository.clearKnowledgeBase() }
    }

    fun clearKeyMetricsCache() {
        viewModelScope.launch {
            preferences.setHistoricalDailyStats("{}")
            preferences.setLastKnownStats("{}")
        }
    }

    fun deleteKnowledgeItem(index: Int) {
        viewModelScope.launch { logRepository.deleteKnowledgeItem(index) }
    }

    fun deleteDocument(doc: com.notel.notel.data.local.entity.KnowledgeDocument) {
        viewModelScope.launch {
            logRepository.deleteDocument(doc)
        }
    }

    fun clearAllDocuments() {
        viewModelScope.launch {
            logRepository.clearAllDocuments()
        }
    }

    fun updateDocumentExtractedText(docId: String, newText: String) {
        viewModelScope.launch {
            logRepository.updateDocumentExtractedText(docId, newText)
        }
    }

    fun editKnowledgeItem(index: Int, newText: String) {
        viewModelScope.launch {
            val currentKb = preferences.knowledgeBase.first()
            val facts = currentKb.split("\n\n").filter { it.isNotBlank() }.toMutableList()
            if (index in facts.indices) {
                facts[index] = newText
                preferences.setKnowledgeBase(facts.joinToString("\n\n"))
                syncManager.pushProfileData()
            }
        }
    }

    fun addProfessionalUpdate(professionalType: String, note: String) {
        viewModelScope.launch {
            val dateStr = java.text.SimpleDateFormat("MMM dd, yyyy", java.util.Locale.getDefault()).format(java.util.Date())
            val newEntry = "From the $professionalType ($dateStr): $note"
            val current = preferences.professionalUpdates.first()
            val combined = if (current.isBlank()) newEntry else "$newEntry\n\n$current"
            preferences.setProfessionalUpdates(combined)
            syncManager.pushProfileData()
        }
    }

    fun deleteProfessionalUpdate(index: Int) {
        viewModelScope.launch {
            val current = preferences.professionalUpdates.first()
            if (current.isNotBlank()) {
                val updatesList = current.split("\n\n").filter { it.isNotBlank() }.toMutableList()
                if (index in updatesList.indices) {
                    updatesList.removeAt(index)
                    preferences.setProfessionalUpdates(updatesList.joinToString("\n\n"))
                    syncManager.pushProfileData()
                }
            }
        }
    }

    fun editProfessionalUpdate(index: Int, newText: String) {
        viewModelScope.launch {
            val current = preferences.professionalUpdates.first()
            if (current.isNotBlank()) {
                val updatesList = current.split("\n\n").filter { it.isNotBlank() }.toMutableList()
                if (index in updatesList.indices) {
                    updatesList[index] = newText
                    preferences.setProfessionalUpdates(updatesList.joinToString("\n\n"))
                    syncManager.pushProfileData()
                }
            }
        }
    }

    fun clearProfessionalUpdates() {
        viewModelScope.launch { 
            preferences.setProfessionalUpdates("")
            syncManager.pushProfileData()
        }
    }

    fun generateProfessionalReport() {
        logRepository.generateProfessionalReportAsync(categories.value, reportGenerator)
    }

    fun generateWeeklyRecap() {
        logRepository.generateWeeklyRecapAsync(categories.value)
    }

    fun generateDeepResearch() {
        logRepository.generateDeepResearchAsync(categories.value)
    }

    fun setAutoAiSuggestions(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setAutoAiSuggestions(enabled)
            syncManager.pushProfileData()
        }
    }

    fun setShareDataWithFriends(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setShareDataWithFriends(enabled)
            syncManager.pushProfileData()
        }
    }

    fun setBodyLoadRemindersEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setBodyLoadRemindersEnabled(enabled)
            syncManager.pushProfileData()
        }
    }

    fun setDailyCupUpdatesEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setDailyCupUpdatesEnabled(enabled)
            syncManager.pushProfileData()
        }
    }

    fun setHrSpikeAlertsEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setHrSpikeAlertsEnabled(enabled)
            syncManager.pushProfileData()
            
            if (enabled) {
                HrSpikeMonitorService.startService(context)
            } else {
                HrSpikeMonitorService.stopService(context)
                // Also cancel any old recursive WorkManager jobs
                androidx.work.WorkManager.getInstance(context).cancelUniqueWork("hr_spike_alert_loop")
            }
        }
    }

    fun setSpikeThreshold(threshold: Int) {
        viewModelScope.launch {
            preferences.setSpikeThreshold(threshold)
            syncManager.pushProfileData()
        }
    }

    fun setHrDeltaEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setHrDeltaEnabled(enabled)
            syncManager.pushProfileData()
        }
    }

    fun setSpikeDeltaThreshold(threshold: Int) {
        viewModelScope.launch {
            preferences.setSpikeDeltaThreshold(threshold)
            syncManager.pushProfileData()
        }
    }

    fun setHabitReminderEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setHabitReminderEnabled(enabled)
            syncManager.pushProfileData()
        }
    }

    fun setProjectReminderEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setProjectReminderEnabled(enabled)
            syncManager.pushProfileData()
        }
    }

    fun clearHabitData() {
        viewModelScope.launch {
            habitRepository.clearHabitData()
        }
    }

    private fun getFileName(uri: android.net.Uri, contentResolver: android.content.ContentResolver): String? {
        var name: String? = null
        val cursor = contentResolver.query(uri, null, null, null, null)
        cursor?.use {
            if (it.moveToFirst()) {
                val index = it.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (index != -1) name = it.getString(index)
            }
        }
        return name
    }

    fun restartOnboarding(onRestart: () -> Unit) {
        viewModelScope.launch {
            preferences.setOnboardingComplete(false)
            // Push the "false" status to the server so it removes the checkmark
            syncManager.pushProfileData() 
            onRestart()
        }
    }

    private val _logoutError = MutableStateFlow<String?>(null)
    val logoutError = _logoutError.asStateFlow()

    fun clearLogoutError() { _logoutError.value = null }

    fun logout(onLogout: () -> Unit) {
        viewModelScope.launch {
            // 0. Push ALL local data to the server BEFORE wiping anything
            try {
                val profilePushed = syncManager.pushProfileData()
                val entriesPushed = syncManager.pushEntries()
                val categoriesPushed = syncManager.pushCategories()
                
                // Verify the sync pushes actually reached the server
                if (!profilePushed || !entriesPushed || !categoriesPushed) {
                    val details = mutableListOf<String>()
                    if (!profilePushed) {
                        val serverErr = syncManager.lastProfilePushError ?: "Unknown error"
                        details.add("Profile: $serverErr")
                    }
                    if (!entriesPushed) details.add("Entries")
                    if (!categoriesPushed) details.add("Categories")
                    _logoutError.value = "Could not verify data was saved to server (Failed: ${details.joinToString(", ")}). Please try again in a moment."
                    return@launch
                }
            } catch (e: Exception) {
                // Sync failed — DO NOT wipe local data
                _logoutError.value = "Could not save data to server: ${e.message ?: "Network error"}. Your data is safe locally. Please try again."
                return@launch
            }

            // 1. Clear DataStore preferences (credentials, tokens, AI context, etc.)
            preferences.clearCredentials()
            
            // 2. Clear Room database (Logs, Insights, Custom Categories)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                database.clearAllTables()
                // 3. Re-seed default categories so the UI isn't empty/broken for next user
                database.categoryDao().insertAll(com.notel.notel.data.local.DefaultCategories.all)
            }
            
            onLogout()
        }
    }

    val eventCounters = preferences.eventCounters.map { json ->
        try {
            if (json.isNotBlank()) Json.decodeFromString<List<EventCounterDto>>(json) else emptyList()
        } catch (e: Exception) { emptyList() }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val counterHistory = preferences.counterHistory.map { json ->
        try {
            if (json.isNotBlank()) Json.decodeFromString<List<CounterHistoryItem>>(json) else emptyList()
        } catch (e: Exception) { emptyList() }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun saveCounter(id: String, name: String, dateMills: Long, isUp: Boolean, autoUp: Boolean) {
        viewModelScope.launch {
            val currentStr = preferences.eventCounters.first()
            val current = try { if (currentStr.isNotBlank()) Json.decodeFromString<MutableList<EventCounterDto>>(currentStr) else mutableListOf() } catch(e: Exception) { mutableListOf() }
            
            val index = current.indexOfFirst { it.id == id }
            if (index >= 0) {
                current[index] = current[index].copy(name = name, targetDate = dateMills, isUp = isUp, autoUp = autoUp)
            } else {
                // Auto-deduplicate: if a counter with this name already exists, append (2), (3), etc.
                val baseName = name.trimEnd()
                val existingNames = current.map { it.name }.toSet()
                val uniqueName = if (!existingNames.contains(baseName)) {
                    baseName
                } else {
                    var suffix = 2
                    var candidate = "$baseName ($suffix)"
                    while (existingNames.contains(candidate)) {
                        suffix++
                        candidate = "$baseName ($suffix)"
                    }
                    candidate
                }
                current.add(EventCounterDto(id, uniqueName, dateMills, isUp, autoUp, isFavorite = current.isEmpty()))
            }
            preferences.setEventCounters(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(EventCounterDto.serializer()), current))
            syncManager.pushProfileData()
        }
    }

    fun toggleArchiveCounter(id: String) {
        viewModelScope.launch {
            val currentStr = preferences.eventCounters.first()
            val current = try { if (currentStr.isNotBlank()) Json.decodeFromString<MutableList<EventCounterDto>>(currentStr) else mutableListOf() } catch(e: Exception) { mutableListOf() }
            
            val index = current.indexOfFirst { it.id == id }
            if (index >= 0) {
                val counter = current[index]
                current[index] = counter.copy(isArchived = !counter.isArchived)
                preferences.setEventCounters(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(EventCounterDto.serializer()), current))
                syncManager.pushProfileData()
            }
        }
    }

    fun endCounterAndSave(id: String) {
        viewModelScope.launch {
            val currentStr = preferences.eventCounters.first()
            val current = try { if (currentStr.isNotBlank()) Json.decodeFromString<MutableList<EventCounterDto>>(currentStr) else mutableListOf() } catch(e: Exception) { mutableListOf() }
            
            val index = current.indexOfFirst { it.id == id }
            if (index >= 0) {
                val counter = current[index]
                current.removeAt(index)
                if (current.isNotEmpty()) {
                    // No longer specifically managing 'isFavorite' as we're removing that system
                }
                preferences.setEventCounters(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(EventCounterDto.serializer()), current))
                
                val historyStr = preferences.counterHistory.first()
                val history = try { if (historyStr.isNotBlank()) Json.decodeFromString<MutableList<CounterHistoryItem>>(historyStr) else mutableListOf() } catch(e: Exception) { mutableListOf() }
                
                history.add(0, CounterHistoryItem(counter.name, counter.targetDate, System.currentTimeMillis()))
                preferences.setCounterHistory(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(CounterHistoryItem.serializer()), history.take(20)))
                syncManager.pushProfileData()
            }
        }
    }

    fun testDailyReminder(context: android.content.Context) {
        viewModelScope.launch {
            com.notel.notel.util.NotificationHelper(context).showBodyLoadReminder()
        }
    }

    

    fun testHabitNotification(context: android.content.Context) {
        viewModelScope.launch {
            // Guaranteed notification for testing/video
            com.notel.notel.util.NotificationHelper(context).showHabitReminder()
        }
    }

    fun testProjectNotification(context: android.content.Context) {
        viewModelScope.launch {
            com.notel.notel.util.NotificationHelper(context).showProjectReminder()
        }
    }

    fun testSpikeNotification(context: android.content.Context) {
        viewModelScope.launch {
            // Try to get real data for realism, but fallback to 102/72 for a guaranteed notification
            val intraday = try { healthConnectManager.readHeartRateIntraday("today") } catch(e: Exception) { emptyList() }
            val latest = intraday.lastOrNull()?.second ?: 102
            val helper = com.notel.notel.util.NotificationHelper(context)
            // Simulating a jump for the test
            helper.showSpikeAlert(latest, latest - 30, 30)
        }
    }

    fun testReminderNotification(context: android.content.Context) {
        val intent = android.content.Intent("com.notel.notel.TEST_REMINDER").apply {
            setPackage(context.packageName)
        }
        context.sendBroadcast(intent)
    }

    fun deleteAiInsight(id: String) {
        viewModelScope.launch {
            val currentStr = preferences.aiInsights.first()
            val current = try { 
                if (currentStr.isNotBlank()) Json.decodeFromString<MutableList<AiInsight>>(currentStr) 
                else mutableListOf() 
            } catch(e: Exception) { mutableListOf() }
            
            val updated = current.filter { it.id != id }
            preferences.setAiInsights(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(AiInsight.serializer()), updated))
            
            try {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    jotApi.deleteInsight(id)
                }
            } catch (e: Exception) {
                // Ignore silent background network failure
            }
        }
    }

    fun recoverAccountData() {
        viewModelScope.launch {
            _isRecovering.value = true
            _isSyncing.value = true
            try {
                if (!preferences.loggedIn.first()) {
                    android.widget.Toast.makeText(context, "Error: Not logged in", android.widget.Toast.LENGTH_SHORT).show()
                    return@launch
                }
                
                val result = syncManager.pullAllData()
                if (result) {
                    val logCount = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        database.logEntryDao().countEntries()
                    }
                    val catCount = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        database.categoryDao().getAllCategories().first().size
                    }
                    android.widget.Toast.makeText(
                        context,
                        "Recovered! $logCount logs, $catCount categories",
                        android.widget.Toast.LENGTH_LONG
                    ).show()
                } else {
                    android.widget.Toast.makeText(
                        context,
                        "Recovery failed — please check your internet connection",
                        android.widget.Toast.LENGTH_LONG
                    ).show()
                }
            } catch (e: Exception) {
                android.widget.Toast.makeText(
                    context,
                    "Recovery error: ${e.message}",
                    android.widget.Toast.LENGTH_LONG
                ).show()
                _syncError.emit(e.message ?: "Failed to recover data")
            } finally {
                _isRecovering.value = false
                _isSyncing.value = false
            }
        }
    }

    fun manualSync() {
        viewModelScope.launch {
            _isManualSyncing.value = true
            try {
                if (!preferences.loggedIn.first()) {
                    android.widget.Toast.makeText(context, "Error: Not logged in", android.widget.Toast.LENGTH_SHORT).show()
                    return@launch
                }
                syncManager.syncAllData()
                android.widget.Toast.makeText(context, "Sync complete!", android.widget.Toast.LENGTH_SHORT).show()
            } catch (e: Exception) {
                android.widget.Toast.makeText(
                    context,
                    "Sync failed: ${e.message}",
                    android.widget.Toast.LENGTH_LONG
                ).show()
                _syncError.emit(e.message ?: "Sync failed")
            } finally {
                _isManualSyncing.value = false
            }
        }
    }

    private val _redditRefreshQueue = MutableStateFlow<List<String>>(emptyList())
    val redditRefreshQueue = _redditRefreshQueue.asStateFlow()
    private var isProcessingQueue = false

    fun addOrRefreshSubreddit(input: String) {
        var sub = input.trim().lowercase()
        if (sub.contains("reddit.com/r/")) {
            sub = sub.substringAfter("reddit.com/r/").substringBefore("/").substringBefore("?")
        }
        sub = sub.removePrefix("/r/").removePrefix("r/").removePrefix("/").removeSuffix("/").trim()

        if (sub.isEmpty() || !sub.matches(Regex("^[a-z0-9_]{2,21}$"))) return
        if (_redditRefreshQueue.value.contains(sub)) return

        _redditRefreshQueue.update { it + sub }
        processRefreshQueue()
    }

    private fun processRefreshQueue() {
        if (isProcessingQueue) return
        viewModelScope.launch {
            isProcessingQueue = true
            while (_redditRefreshQueue.value.isNotEmpty()) {
                val sub = _redditRefreshQueue.value.first()
                _isRefreshingReddit.value = sub
                try {
                    val ctx = preferences.userContext.first()
                    val request = com.notel.notel.data.remote.FetchSubredditRequest(subreddit = sub, userContext = ctx)
                    val response = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        jotApi.fetchSubreddit(request)
                    }

                    if (response.isSuccessful) {
                        val body = response.body()
                        if (body?.result != null) {
                            // 1. Update/add to subreddit list with timestamp
                            val currentStr = preferences.redditSubreddits.first()
                            val current: MutableList<LinkedSubreddit> = try {
                                if (currentStr.isNotBlank() && currentStr != "[]") 
                                    Json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(LinkedSubreddit.serializer()), currentStr).toMutableList()
                                else mutableListOf()
                            } catch (e: Exception) { mutableListOf() }
                            
                            val existing = current.indexOfFirst { it.name == sub }
                            val currentAutoUpdate = if (existing >= 0) current[existing].autoUpdate else true // Default to true for new ones
                            val entry = LinkedSubreddit(
                                name = sub, 
                                lastFetched = System.currentTimeMillis(), 
                                postsAnalyzed = body.posts?.size ?: 0, 
                                autoUpdate = currentAutoUpdate,
                                scannedPosts = body.posts ?: emptyList()
                            )
                            if (existing >= 0) current[existing] = entry else current.add(0, entry)
                            preferences.setRedditSubreddits(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(LinkedSubreddit.serializer()), current))

                            // 2. Replace old Reddit summary entry for this subreddit and prepend fresh one
                            val timestamp = java.text.SimpleDateFormat("MMMM d, yyyy", java.util.Locale.US).format(java.util.Date())
                            val redditMarker = "[REDDIT r/$sub]"
                            val newEntry = "[ADDED $timestamp] $redditMarker\n${body.result}"
                            val currentRedditSummaries = preferences.redditSummaries.first()
                            val filteredReddit = currentRedditSummaries.split("\n\n")
                                .filter { !it.contains(redditMarker) }
                                .joinToString("\n\n")
                            val updatedReddit = if (filteredReddit.isBlank()) newEntry else "$newEntry\n\n$filteredReddit"
                            preferences.setRedditSummaries(updatedReddit)
                            syncManager.syncAllData()
                            _redditSynced.emit("Integrated r/$sub community knowledge")
                        } else {
                            _redditError.emit("No content returned for r/$sub")
                        }
                    } else {
                        val errMsg = response.errorBody()?.string()?.let {
                            try { org.json.JSONObject(it).optString("error", "Failed to fetch subreddit") } catch (_: Exception) { "Failed to fetch subreddit" }
                        } ?: "Failed to fetch subreddit"
                        _redditError.emit(errMsg)
                    }
                } catch (e: Exception) {
                    _redditError.emit("Connection error scanning r/$sub")
                    e.printStackTrace()
                } finally {
                    _isRefreshingReddit.value = null
                    _redditRefreshQueue.update { it.drop(1) }
                    kotlinx.coroutines.delay(500)
                }
            }
            isProcessingQueue = false
        }
    }

    fun removeSubreddit(subredditName: String) {
        viewModelScope.launch {
            val currentStr = preferences.redditSubreddits.first()
            val current: MutableList<LinkedSubreddit> = try {
                if (currentStr.isNotBlank() && currentStr != "[]") Json.decodeFromString(currentStr) else mutableListOf()
            } catch (e: Exception) { mutableListOf() }
            current.removeAll { it.name == subredditName }
            preferences.setRedditSubreddits(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(LinkedSubreddit.serializer()), current))

            // Also remove its summary entry
            val redditMarker = "[REDDIT r/$subredditName]"
            val currentRedditSummaries = preferences.redditSummaries.first()
            val filteredReddit = currentRedditSummaries.split("\n\n").filter { !it.contains(redditMarker) }.joinToString("\n\n")
            preferences.setRedditSummaries(filteredReddit)
            syncManager.syncAllData()
        }
    }

    fun toggleAutoUpdate(subredditName: String) {
        viewModelScope.launch {
            val currentStr = preferences.redditSubreddits.first()
            val current: MutableList<LinkedSubreddit> = try {
                if (currentStr.isNotBlank() && currentStr != "[]") Json.decodeFromString(currentStr) else mutableListOf()
            } catch (e: Exception) { mutableListOf() }
            val idx = current.indexOfFirst { it.name == subredditName }
            if (idx >= 0) {
                current[idx] = current[idx].copy(autoUpdate = !current[idx].autoUpdate)
                preferences.setRedditSubreddits(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(LinkedSubreddit.serializer()), current))
                syncManager.syncAllData()
            }
        }
    }

    fun getSubredditSummary(subredditName: String): String {
        val summaries = redditSummaries.value
        val marker = "r/$subredditName]"
        val entries = summaries.split("\n\n")
        val found = entries.find { it.contains(marker) }
        return found?.substringAfter(marker)?.trim() ?: "No summary found."
    }

    fun getSubredditPosts(subredditName: String): List<com.notel.notel.data.remote.RedditPost> {
        return redditSubreddits.value.find { it.name == subredditName }?.scannedPosts ?: emptyList()
    }

    fun refreshThisWeeksScores() {
        viewModelScope.launch {
            var cats = categories.value
            if (cats.isEmpty()) {
                addSystemLog("Refresh: categories.value is empty, querying repository flow...")
                cats = categoryRepository.getAllCategories().first()
            }
            if (cats.isEmpty()) {
                addSystemLog("Refresh: Category list is empty, aborting.")
                return@launch
            }
            addSystemLog("Refresh: Starting force refresh of this week's scores...")
            val today = java.time.LocalDate.now()
            
            val targetDays = (0..6).map { today.minusDays(it.toLong()).toString() }
            addSystemLog("Refresh: Clearing scores for target week...")
            logRepository.clearBodyLoadInsightsForDays(targetDays)
            addSystemLog("Refresh: Saving cleared scores database state...")

            for (i in 0..6) {
                val dateStr = today.minusDays(i.toLong()).toString()
                addSystemLog("Refresh: Recalculating score for $dateStr...")
                logRepository.getBodyLoad(cats, dateStr)
                addSystemLog("Refresh: Done calculating score for $dateStr.")
            }
            
            addSystemLog("Refresh: Weekly recalculation completed! Performing final sync...")
            syncManager.syncAllData()
            addSystemLog("Refresh: Final sync done.")
        }
    }

    private fun isSameDay(t1: Long, t2: Long): Boolean {
        val d1 = java.time.Instant.ofEpochMilli(t1).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        val d2 = java.time.Instant.ofEpochMilli(t2).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        return d1 == d2
    }

    fun updateNickname(nickname: String, onResult: (Boolean, String?) -> Unit) {
        val trimmed = nickname.trim().replace("\\s+".toRegex(), " ")

        // Validation Rules
        if (trimmed.length < 2) {
            onResult(false, "Nickname must be at least 2 characters")
            return
        }

        val lettersOnly = "^[a-zA-Z ]+$".toRegex()
        if (!trimmed.matches(lettersOnly)) {
            onResult(false, "Nickname can only contain letters and spaces")
            return
        }

        val spaceCount = trimmed.count { it == ' ' }
        if (spaceCount > 2) {
            onResult(false, "Nickname can contain at most 2 spaces")
            return
        }

        viewModelScope.launch {
            try {
                // Push update to server directly (no uniqueness check needed for duplicate nicknames)
                val updateRes = jotApi.updateNickname(com.notel.notel.data.remote.UpdateNicknameRequest(trimmed))
                val body = updateRes.body()
                if (updateRes.isSuccessful && body?.success == true) {
                    preferences.setUserNickname(trimmed)
                    body.tag?.let { preferences.setUserTag(it) }
                    onResult(true, null)
                } else {
                    onResult(false, body?.error ?: "Failed to update nickname on the server")
                }
            } catch (e: Exception) {
                onResult(false, e.message ?: "Network error")
            }
        }
    }

    fun setCustomStreak(current: Int, best: Int) {
        viewModelScope.launch {
            preferences.setCurrentStreak(current)
            preferences.setBestStreak(best)
            syncManager.pushProfileData()
            addSystemLog("Developer: Streak updated to current=$current, best=$best")
        }
    }
}

@kotlinx.serialization.Serializable
data class EventCounterDto(
    val id: String,
    val name: String,
    val targetDate: Long,
    val isUp: Boolean,
    val autoUp: Boolean,
    val isFavorite: Boolean = false,
    val isArchived: Boolean = false
)

@kotlinx.serialization.Serializable
data class CounterHistoryItem(
    val name: String,
    val targetDate: Long,
    val endedAt: Long
)

@kotlinx.serialization.Serializable
data class LinkedSubreddit(
    val name: String,
    val lastFetched: Long = 0L,
    val postsAnalyzed: Int = 0,
    val autoUpdate: Boolean = false,
    val scannedPosts: List<com.notel.notel.data.remote.RedditPost> = emptyList()
)

data class SystemLog(
    val body: String,
    val timestamp: Long
)

