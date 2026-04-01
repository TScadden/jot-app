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
    @ApplicationContext private val context: android.content.Context
) : ViewModel() {


    val userContext = preferences.userContext
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val knowledgeBase = preferences.knowledgeBase
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val professionalUpdates = preferences.professionalUpdates
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val processedFiles = preferences.processedFiles
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

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

    val userBalance = preferences.userBalance
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0f)

    val autoAiSuggestions = preferences.autoAiSuggestions
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val settingsTutorialSeen: StateFlow<Boolean?> = preferences.settingsTutorialSeen
        .map { it as Boolean? }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val bodyLoadRemindersEnabled = preferences.bodyLoadRemindersEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val dailyCupUpdatesEnabled = preferences.dailyCupUpdatesEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val hrSpikeAlertsEnabled = preferences.hrSpikeAlertsEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val reportReadyEvent = logRepository.reportReadyEvent

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


    fun topUpBalance(amount: Float) {
        // This was the old simulation method
        viewModelScope.launch {
            val current = preferences.userBalance.first()
            preferences.setUserBalance(current + amount)
        }
    }

    fun purchaseCredits(activity: android.app.Activity, productId: String, quantity: Int = 1) {
        billingManager.launchPurchaseFlow(activity, productId, quantity)
    }

    fun saveUserContext(text: String) {
        viewModelScope.launch { preferences.setUserContext(text) }
    }

    fun saveUserProfile(age: Int, height: Float, weight: Float, gender: String) {
        viewModelScope.launch {
            preferences.setUserProfileStats(age, height, weight, gender)
            syncManager.syncAllData()
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
                    val hcWeight = healthConnectManager.readLatestWeight()
                    val hcHeight = healthConnectManager.readLatestHeight()
                    if (hcWeight != null && hcWeight > 0f) newWeight = Math.round(hcWeight * 10) / 10f
                    if (hcHeight != null && hcHeight > 0f) newHeight = Math.round(hcHeight * 10) / 10f
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
                                val fHeight = user?.get("height")?.jsonPrimitive?.floatOrNull // Could be in cm or inches depending on unit system
                                val fWeight = user?.get("weight")?.jsonPrimitive?.floatOrNull // Could be kg or lbs... let's assume raw units are standard based on default
                                val fGender = user?.get("gender")?.jsonPrimitive?.content
                                
                                if (fAge != null && fAge > 0) newAge = fAge
                                if (!fGender.isNullOrBlank()) newGender = fGender
                                if (fHeight != null && fHeight > 0f) newHeight = fHeight
                                if (fWeight != null && fWeight > 0f) newWeight = fWeight
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

    fun deleteKnowledgeItem(index: Int) {
        viewModelScope.launch { logRepository.deleteKnowledgeItem(index) }
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
            syncManager.syncAllData()
        }
    }

    fun setBodyLoadRemindersEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setBodyLoadRemindersEnabled(enabled)
            syncManager.syncAllData()
        }
    }

    fun setDailyCupUpdatesEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setDailyCupUpdatesEnabled(enabled)
            syncManager.syncAllData()
        }
    }

    fun setHrSpikeAlertsEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setHrSpikeAlertsEnabled(enabled)
            syncManager.syncAllData()
            
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
            syncManager.syncAllData()
        }
    }

    fun setHrDeltaEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setHrDeltaEnabled(enabled)
            syncManager.syncAllData()
        }
    }

    fun setSpikeDeltaThreshold(threshold: Int) {
        viewModelScope.launch {
            preferences.setSpikeDeltaThreshold(threshold)
            syncManager.syncAllData()
        }
    }

    fun setHabitReminderEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setHabitReminderEnabled(enabled)
            syncManager.syncAllData()
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
            syncManager.syncAllData() 
            onRestart()
        }
    }

    fun logout(onLogout: () -> Unit) {
        viewModelScope.launch {
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
                current.add(EventCounterDto(id, name, dateMills, isUp, autoUp, isFavorite = current.isEmpty()))
            }
            preferences.setEventCounters(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(EventCounterDto.serializer()), current))
        }
    }

    fun toggleFavoriteCounter(id: String) {
        viewModelScope.launch {
            val currentStr = preferences.eventCounters.first()
            val current = try { if (currentStr.isNotBlank()) Json.decodeFromString<MutableList<EventCounterDto>>(currentStr) else mutableListOf() } catch(e: Exception) { mutableListOf() }
            
            val updated = current.map { it.copy(isFavorite = it.id == id) }
            preferences.setEventCounters(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(EventCounterDto.serializer()), updated))
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
                if (counter.isFavorite && current.isNotEmpty()) {
                    current[0] = current[0].copy(isFavorite = true)
                }
                preferences.setEventCounters(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(EventCounterDto.serializer()), current))
                
                val historyStr = preferences.counterHistory.first()
                val history = try { if (historyStr.isNotBlank()) Json.decodeFromString<MutableList<CounterHistoryItem>>(historyStr) else mutableListOf() } catch(e: Exception) { mutableListOf() }
                
                history.add(0, CounterHistoryItem(counter.name, counter.targetDate, System.currentTimeMillis()))
                preferences.setCounterHistory(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(CounterHistoryItem.serializer()), history.take(20)))
            }
        }
    }

    fun testDailyReminder(context: android.content.Context) {
        viewModelScope.launch {
            com.notel.notel.util.NotificationHelper(context).showBodyLoadReminder()
        }
    }

    fun testBodyLoadNotification(context: android.content.Context) {
        viewModelScope.launch {
            logRepository.getBodyLoad(categories.value).fold(
                onSuccess = { res ->
                    com.notel.notel.util.NotificationHelper(context).showBodyLoadUpdate(res.score)
                },
                onFailure = {
                    com.notel.notel.util.NotificationHelper(context).showBodyLoadReminder()
                }
            )
        }
    }

    fun testHabitNotification(context: android.content.Context) {
        viewModelScope.launch {
            habitRepository.fetchHabits()
            val habits = habitRepository.habits.value
            val today = habitRepository.todayDateString()
            val anyUnchecked = habits.any { today !in it.logs }
            
            val helper = com.notel.notel.util.NotificationHelper(context)
            if (anyUnchecked) {
                helper.showHabitReminder()
            } else {
                // For testing, we'll show the reminder even if all are checked, 
                // so the user can verify the notification style.
                helper.showHabitReminder()
            }
        }
    }

    fun testSpikeNotification(context: android.content.Context) {
        viewModelScope.launch {
            val intraday = healthConnectManager.readHeartRateIntraday("today")
            val latest = intraday.lastOrNull()?.second ?: 102
            val helper = com.notel.notel.util.NotificationHelper(context)
            // Simulating a +30 jump for the test
            helper.showSpikeAlert(latest, latest - 30, 30)
        }
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
        }
    }

    fun recoverAccountData() {
        viewModelScope.launch {
            _isSyncing.value = true
            try {
                syncManager.pullAllData()
            } catch (e: Exception) {
                _syncError.emit(e.message ?: "Failed to recover data")
            } finally {
                _isSyncing.value = false
            }
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
    val isFavorite: Boolean
)

@kotlinx.serialization.Serializable
data class CounterHistoryItem(
    val name: String,
    val targetDate: Long,
    val endedAt: Long
)
