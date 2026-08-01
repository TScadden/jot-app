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
import com.notel.notel.data.BleManager
import com.notel.notel.data.BleDevice
import com.notel.notel.data.ConnectionState
import com.notel.notel.service.HeartRateLoggingService
import java.io.File
import com.notel.notel.data.sync.SyncManager

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences,
    private val categoryRepository: CategoryRepository,
    private val reportGenerator: com.notel.notel.util.ReportGenerator,
    val healthConnectManager: HealthConnectManager,
    val billingManager: com.notel.notel.data.billing.BillingManager,
    val syncManager: SyncManager,
    private val database: com.notel.notel.data.local.NotelDatabase,
    private val habitRepository: com.notel.notel.data.repository.HabitRepository,
    private val tabsApi: com.notel.notel.data.remote.TabsApi,
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

    val professionalUpdates = preferences.professionalUpdates
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

    val googleCalendarConnected = preferences.googleCalendarConnected
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val googleCalendarEmail = preferences.googleCalendarEmail
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val bleAutoConnectEnabled = preferences.bleAutoConnectEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    fun setBleAutoConnectEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setBleAutoConnectEnabled(enabled)
        }
    }

    fun connectGoogleCalendar(email: String) {
        viewModelScope.launch {
            preferences.setGoogleCalendarConnected(true)
            preferences.setGoogleCalendarEmail(email)
        }
    }

    fun disconnectGoogleCalendar() {
        viewModelScope.launch {
            preferences.setGoogleCalendarConnected(false)
            preferences.setGoogleCalendarEmail("")
        }
    }


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
        backfillDocumentExtractions()
        migrateOldCsvFiles()
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

    private fun migrateOldCsvFiles() {
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            try {
                val csvFiles = context.filesDir.listFiles { _, name -> 
                    name.startsWith("heart_rate_session_") && name.endsWith(".csv") 
                } ?: return@launch
                
                for (file in csvFiles) {
                    val lines = file.readLines()
                    if (lines.isEmpty()) continue
                    
                    // Check if this file has already been migrated or uses the old format
                    val needsMigration = lines.any { it.startsWith("====") }
                    if (!needsMigration) continue
                    
                    // Parse data rows
                    val dataRows = lines.filter { line ->
                        val parts = line.split(",")
                        if (parts.size >= 2) {
                            val bpmClean = parts[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                            bpmClean.toIntOrNull() != null && parts[0].contains(":") && !parts[0].contains("BPM")
                        } else false
                    }
                    
                    if (dataRows.isEmpty()) continue
                    
                    // Extract values from old headers if possible
                    var dateStr = "N/A"
                    var startTimeStr = "N/A"
                    var endTimeStr = "N/A"
                    var durationText = "Unknown"
                    var minHrVal = "0"
                    var maxHrVal = "0"
                    var max15sJumpVal = "0"
                    
                    for (line in lines) {
                        when {
                            line.contains("Date:") -> dateStr = line.substringAfter("Date:").trim()
                            line.contains("Start Time:") -> startTimeStr = line.substringAfter("Start Time:").trim()
                            line.contains("End Time:") -> endTimeStr = line.substringAfter("End Time:").trim()
                            line.contains("Duration:") -> durationText = line.substringAfter("Duration:").trim()
                            line.contains("[ MIN HR ]") -> minHrVal = line.substringAfter("MIN HR ]").replace("BPM", "").trim()
                            line.contains("[ AVG HR ]") -> {} // recalculated below
                            line.contains("[ MAX HR ]") -> maxHrVal = line.substringAfter("MAX HR ]").replace("BPM", "").trim()
                            line.contains("[ 15S MAX JUMP ]") -> max15sJumpVal = line.substringAfter("15S MAX JUMP ]").replace("BPM", "").trim()
                        }
                    }
                    
                    val heartRates = dataRows.mapNotNull { line ->
                        val bpmClean = line.split(",")[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                        bpmClean.toIntOrNull()
                    }
                    if (heartRates.isEmpty()) continue
                    
                    val avgHr = heartRates.average().toInt()
                    
                    // Recalculate spikes >= 100 BPM
                    val spikesOver100 = dataRows.mapNotNull { line ->
                        val parts = line.split(",")
                        if (parts.size >= 2) {
                            val timeStr = parts[0].trim()
                            val bpmClean = parts[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                            val bpmVal = bpmClean.toIntOrNull()
                            if (bpmVal != null && bpmVal >= 100) timeStr to bpmVal else null
                        } else null
                    }
                    
                    val spikesText = if (spikesOver100.isEmpty()) {
                        "  [ SPIKES ],None detected\n"
                    } else {
                        val spikesLines = spikesOver100.map { (time, bpm) ->
                            val timeOnly = if (time.contains(" ")) time.substringAfter(" ") else time
                            "  [ SPIKE ],$timeOnly ([$bpm BPM])\n"
                        }
                        "  [ SPIKES ],${spikesOver100.size} detected:\n" + spikesLines.joinToString("")
                    }
                    
                    // Rewrite file with new format and [XX BPM] formatted heart rates
                    file.bufferedWriter().use { writer ->
                        writer.write("-----------------------------------------------------,\n")
                        writer.write("               JOT LIVE SESSION LOG,\n")
                        writer.write("-----------------------------------------------------,\n")
                        writer.write("  Date:,$dateStr\n")
                        writer.write("  Start Time:,$startTimeStr\n")
                        writer.write("  End Time:,$endTimeStr\n")
                        writer.write("  Duration:,$durationText\n")
                        writer.write("-----------------------------------------------------,\n")
                        writer.write("  STATISTICS:,\n")
                        writer.write("  [ MIN HR ],$minHrVal BPM\n")
                        writer.write("  [ AVG HR ],$avgHr BPM\n")
                        writer.write("  [ MAX HR ],$maxHrVal BPM\n")
                        writer.write("  [ 15S MAX JUMP ],$max15sJumpVal BPM\n")
                        writer.write(spikesText)
                        writer.write("-----------------------------------------------------,\n\n")
                        writer.write("Timestamp,Heart Rate\n")
                        
                        dataRows.forEach { line ->
                            val parts = line.split(",")
                            val timeStr = parts[0].trim()
                            val bpmClean = parts[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                            writer.write("$timeStr,[$bpmClean BPM]\n")
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
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
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val userNickname = preferences.userNickname
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val userTag = preferences.userTag
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val shareDataWithFriends = preferences.shareDataWithFriends
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val hrSpikeAlertsEnabled = preferences.hrSpikeAlertsEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val medications = preferences.medications.map { json ->
        try {
            if (json.isNotBlank()) Json.decodeFromString<List<Medication>>(json) else emptyList()
        } catch (e: Exception) { emptyList() }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

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

    val eventReminderEnabled = preferences.eventReminderEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    fun setEventReminderEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setEventReminderEnabled(enabled)
            syncManager.pushProfileData()
        }
    }

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
            
            // Debounce pushing profile changes to the server by 3 seconds (3000ms)
            pushContextJob?.cancel()
            pushContextJob = viewModelScope.launch {
                kotlinx.coroutines.delay(3000)
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

    fun addMedication(name: String, startDate: String, endDate: String, isPresent: Boolean) {
        viewModelScope.launch {
            val current = medications.value.toMutableList()
            val newMed = Medication(
                id = java.util.UUID.randomUUID().toString(),
                name = name,
                startDate = startDate,
                endDate = if (isPresent) "Present" else endDate,
                isPresent = isPresent
            )
            current.add(newMed)
            preferences.setMedications(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(Medication.serializer()), current))
            syncManager.pushProfileData()
        }
    }

    fun deleteMedication(id: String) {
        viewModelScope.launch {
            val current = medications.value.filter { it.id != id }
            preferences.setMedications(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(Medication.serializer()), current))
            syncManager.pushProfileData()
        }
    }

    fun extractMedicationsFromText(
        text: String,
        docText: String,
        onResult: (List<Medication>) -> Unit,
        onError: (String) -> Unit
    ) {
        viewModelScope.launch {
            val prompt = """
            You are a precise clinical data extraction AI. Extract all medications mentioned in the following user text and document content.
            For each medication, return:
            1. Medication Name (correct spelling and grammar)
            2. Start Date (e.g. "Jun 2026", "2026-06-25", or empty string if not mentioned)
            3. End Date (e.g. "Jul 2026", or "Present" if the user is still taking it or there is no indication of stopping)
            4. isPresent (boolean: true if the end date is "Present", false otherwise)

            Return ONLY a raw JSON array matching this exact schema:
            [
              {
                "id": "generate-a-unique-uuid",
                "name": "Medication Name",
                "startDate": "Start Date",
                "endDate": "End Date or Present",
                "isPresent": true
              }
            ]
            Do not output any markdown code blocks, explanation, or other text. Simply output the JSON array.
            
            User text:
            $text
            
            Document context:
            $docText
            """.trimIndent()
            
            try {
                val result = logRepository.getAiExtraction(prompt)
                result.fold(
                    onSuccess = { responseText ->
                        try {
                            val cleanJson = responseText.trim()
                                .removePrefix("```json")
                                .removePrefix("```")
                                .removeSuffix("```")
                                .trim()
                            val parsed = Json.decodeFromString<List<Medication>>(cleanJson)
                            
                            val updated = (medications.value + parsed).distinctBy { it.name.lowercase().trim() }
                            preferences.setMedications(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(Medication.serializer()), updated))
                            syncManager.pushProfileData()
                            
                            onResult(parsed)
                        } catch (e: Exception) {
                            onError("Failed to parse medication details from AI response: ${e.message}")
                        }
                    },
                    onFailure = { err ->
                        onError(err.message ?: "AI Extraction failed")
                    }
                )
            } catch (e: Exception) {
                onError(e.message ?: "An error occurred during AI extraction")
            }
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

            val finalItem = current.firstOrNull { it.id == id } ?: current.lastOrNull()
            if (finalItem != null) {
                com.notel.notel.notifications.EventScheduler.scheduleEventNotification(context, finalItem.id, finalItem.name, finalItem.targetDate)
            }
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
                    tabsApi.deleteInsight(id)
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
                val updateRes = tabsApi.updateNickname(com.notel.notel.data.remote.UpdateNicknameRequest(trimmed))
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

    // --- JOT LIVE HEART RATE BLE ---
    private val bleManager = BleManager.getInstance(context)

    val bleConnectionState = bleManager.connectionState
    val scannedBleDevices = bleManager.scannedDevices
    val liveHeartRate = bleManager.liveHeartRate
    val bleRawBytes = bleManager.rawBytes
    val isBleSwitchingConnection = bleManager.isSwitchingConnection

    val isHrLoggingServiceRunning = HeartRateLoggingService.isServiceRunning
    val hrActiveFileName = HeartRateLoggingService.activeFileName
    val hrSessionMin = HeartRateLoggingService.sessionMinHr
    val hrSessionMax = HeartRateLoggingService.sessionMaxHr
    val hrMax15sJump = HeartRateLoggingService.max15sJump

    val hasVisibleBandAsked = preferences.hasVisibleBandAsked
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val heartRateHistory = preferences.heartRateHistory
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "[]")

    private val _isPullingTelemetry = MutableStateFlow(false)
    val isPullingTelemetry = _isPullingTelemetry.asStateFlow()

    fun pullTelemetryFromServer() {
        viewModelScope.launch {
            _isPullingTelemetry.value = true
            syncManager.pullAllData()
            _isPullingTelemetry.value = false
        }
    }

    fun markVisibleBandAsked() {
        viewModelScope.launch {
            preferences.setHasVisibleBandAsked(true)
            syncManager.pushProfileData()
        }
    }

    fun startBleScan() {
        bleManager.startScanning()
    }

    fun stopBleScan() {
        bleManager.stopScanning()
    }

    fun connectBleDevice(device: BleDevice) {
        bleManager.connectToDevice(device)
    }

    fun disconnectBle(explicit: Boolean) {
        bleManager.disconnect(explicit)
    }

    fun setBleSwitchingConnection(value: Boolean) {
        bleManager.setSwitchingConnection(value)
    }

    fun startHrLoggingService(device: BleDevice) {
        val intent = android.content.Intent(context, HeartRateLoggingService::class.java).apply {
            action = HeartRateLoggingService.ACTION_START
            putExtra(HeartRateLoggingService.EXTRA_DEVICE_ADDRESS, device.address)
            putExtra(HeartRateLoggingService.EXTRA_DEVICE_NAME, device.name)
        }
        androidx.core.content.ContextCompat.startForegroundService(context, intent)
        addSystemLog("Tabs Live: Background session started for ${device.name}")
    }

    fun stopHrLoggingService() {
        val intent = android.content.Intent(context, HeartRateLoggingService::class.java).apply {
            action = HeartRateLoggingService.ACTION_STOP
        }
        context.startService(intent)
        addSystemLog("Tabs Live: Background session stopped")
    }

    fun deleteSessionCsvFile(file: File, onDeleted: () -> Unit) {
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            if (file.exists() && file.delete()) {
                addSystemLog("Tabs Live: Log file ${file.name} deleted")
                launch(kotlinx.coroutines.Dispatchers.Main) {
                    onDeleted()
                }
            }
        }
    }

    fun deleteAccount(onSuccess: () -> Unit, onError: (String) -> Unit) {
        viewModelScope.launch {
            logRepository.deleteAccountData().fold(
                onSuccess = {
                    onSuccess()
                },
                onFailure = { error ->
                    onError(error.message ?: "Failed to delete account data")
                }
            )
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



data class SystemLog(
    val body: String,
    val timestamp: Long
)

@kotlinx.serialization.Serializable
data class Medication(
    val id: String,
    val name: String,
    val startDate: String,
    val endDate: String,
    val isPresent: Boolean = false
)

