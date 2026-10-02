package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
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
import com.notel.notel.data.remote.LogoutRequest

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
    val conditionRepository: com.notel.notel.data.repository.ConditionRepository,
    @ApplicationContext private val context: android.content.Context
) : ViewModel() {

    companion object {
        private const val TAG = "SettingsViewModel"
    }

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

    val userEmail = preferences.userEmail
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val lastSyncTime = preferences.lastSyncTime
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0L)

    // Playground: Progress Reports appointment card (persisted in DataStore).
    val appointmentDate = preferences.appointmentDate
    val appointmentReportType = preferences.appointmentReportType

    fun saveAppointment(dateIso: String?, reportType: String) {
        viewModelScope.launch {
            preferences.setAppointmentDate(dateIso)
            preferences.setAppointmentReportType(reportType)
            // Day-before nudge: schedule (or reschedule) the 9 AM reminder.
            // No-ops when exact alarms are revoked or the fire time passed.
            if (dateIso != null) {
                com.notel.notel.notifications.AppointmentReminderScheduler.schedule(context, dateIso)
            } else {
                com.notel.notel.notifications.AppointmentReminderScheduler.cancel(context)
            }
        }
    }

    fun clearAppointment() {
        viewModelScope.launch {
            preferences.setAppointmentDate(null)
            preferences.setAppointmentReportType("health")
            com.notel.notel.notifications.AppointmentReminderScheduler.cancel(context)
        }
    }

    // Otto's feature: report type/range continuity for Progress Reports.
    // Phase 1 (WS-A): the boolean range became a range key + concrete bounds.
    val lastReportType = preferences.lastReportType
    val lastReportRangeKey = preferences.lastReportRangeKey
    val lastReportRangeStart = preferences.lastReportRangeStart
    val lastReportRangeEnd = preferences.lastReportRangeEnd
    val lastReportFocusText = preferences.lastReportFocusText

    fun saveLastReportPrefs(
        reportType: String,
        range: com.notel.notel.data.model.ReportRange,
        focusText: String = ""
    ) {
        viewModelScope.launch {
            val now = System.currentTimeMillis()
            val resolved = range.toClinicalReportRange(now)
            preferences.saveLastReportPrefs(
                reportType = reportType,
                rangeKey = range.prefsKey,
                rangeStartMs = resolved.startEpochMs,
                rangeEndMs = resolved.endEpochMs,
                focusText = focusText
            )
        }
    }

    // Mason's feature: last successful export timestamp.
    val lastReportExportTime = preferences.lastReportExportTime

    fun markReportExported() {
        viewModelScope.launch {
            preferences.setLastReportExportTime(System.currentTimeMillis())
        }
    }

    // Phase 2 (WS-D): lightweight trend-preview snapshot. Local logs (same
    // range/focus filter as the export) plus cached metrics only — no live
    // Health Connect reads, so it stays fast and deterministic. Aggregated
    // with the same pure functions as the PDF, so preview and export agree
    // for identical inputs.
    private val _reportPreviewSnapshot =
        MutableStateFlow<com.notel.notel.data.model.ClinicalReportData?>(null)
    val reportPreviewSnapshot = _reportPreviewSnapshot.asStateFlow()
    private var previewJob: kotlinx.coroutines.Job? = null

    fun refreshReportPreview(
        range: com.notel.notel.data.model.ReportRange = com.notel.notel.data.model.ReportRange.Last30Days,
        focus: com.notel.notel.data.model.ReportFocus = com.notel.notel.data.model.ReportFocus.Health,
        customCategoryIds: Set<Int> = emptySet()
    ) {
        previewJob?.cancel()
        previewJob = viewModelScope.launch {
            try {
                val cats = categories.value
                _reportPreviewSnapshot.value =
                    logRepository.clinicalReportDataCollector.collectPreviewSnapshot(
                        allCategories = cats,
                        range = range,
                        focus = focus,
                        customCategoryIds = customCategoryIds
                    )
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                // The preview is advisory; a failure here must never break the
                // export path. The previous snapshot (if any) stays on screen.
                android.util.Log.w(TAG, "Report preview snapshot failed: ${e.javaClass.simpleName}")
            }
        }
    }

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

    val googleAccountConnected = preferences.googleAccountConnected
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val googleAccountEmail = preferences.googleAccountEmail
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    val bleAutoConnectEnabled = preferences.bleAutoConnectEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val showNavLabels = preferences.showNavLabels
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    fun setShowNavLabels(show: Boolean) {
        viewModelScope.launch {
            preferences.setShowNavLabels(show)
        }
    }

    val themeMode = preferences.themeMode
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), com.notel.notel.ui.theme.ThemeMode.DARK)

    fun setThemeMode(mode: com.notel.notel.ui.theme.ThemeMode) {
        viewModelScope.launch {
            preferences.setThemeMode(mode)
        }
    }

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

    fun connectGoogleAccount(idToken: String, email: String, onResult: (Boolean, String?) -> Unit) {
        viewModelScope.launch {
            try {
                val response = tabsApi.linkGoogle(
                    com.notel.notel.data.remote.LinkGoogleRequest(idToken)
                )
                val body = response.body()
                if (response.isSuccessful && body?.success == true) {
                    preferences.setGoogleAccountConnected(true)
                    preferences.setGoogleAccountEmail(email)
                    onResult(true, body.message)
                } else {
                    android.util.Log.e(TAG, "linkGoogle failed: ${response.code()}")
                    onResult(false, com.notel.notel.util.FriendlyErrors.forBackendError(
                        TAG, null, com.notel.notel.util.FriendlyErrors.Kind.AUTH
                    ).banner)
                }
            } catch (e: Exception) {
                // Linking must fail closed. Never update local connection state
                // unless the server verified and persisted the Google identity.
                onResult(false, "Could not verify Google account. Check your connection and try again.")
            }
        }
    }

    fun disconnectGoogleAccount(onResult: (Boolean, String?) -> Unit) {
        viewModelScope.launch {
            try {
                val res = tabsApi.disconnectGoogle()
                if (res.isSuccessful && res.body()?.error == null) {
                    preferences.setGoogleAccountConnected(false)
                    preferences.setGoogleAccountEmail("")
                    onResult(true, "Google account disconnected successfully.")
                } else {
                    val err = res.body()?.error ?: "Failed to disconnect Google account"
                    android.util.Log.e(TAG, "disconnectGoogle failed: ${res.code()} err=$err")
                    onResult(false, com.notel.notel.util.FriendlyErrors.forBackendError(
                        TAG, null, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN
                    ).banner)
                }
            } catch (e: Exception) {
                // Preserve local state when the server could not confirm disconnection.
                onResult(false, "Could not disconnect Google account. Check your connection and try again.")
            }
        }
    }

    fun disconnectGoogleAccountWithPassword(password: String, confirmPassword: String, onResult: (Boolean, String?) -> Unit) {
        if (password.length < 6) {
            onResult(false, "Password must be at least 6 characters")
            return
        }
        if (password != confirmPassword) {
            onResult(false, "Passwords do not match")
            return
        }
        viewModelScope.launch {
            try {
                val res = tabsApi.updatePassword(com.notel.notel.data.remote.UpdatePasswordRequest(password))
                if (res.isSuccessful && res.body()?.error == null) {
                    preferences.setGoogleAccountConnected(false)
                    preferences.setGoogleAccountEmail("")
                    onResult(true, "Password set successfully. Google account disconnected.")
                } else {
                    val err = res.body()?.error ?: "Failed to set password"
                    onResult(false, err)
                }
            } catch (e: Exception) {
                // In case of error, set preferences locally and inform user
                preferences.setGoogleAccountConnected(false)
                preferences.setGoogleAccountEmail("")
                onResult(true, "Google account disconnected.")
            }
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
                android.util.Log.e("SettingsViewModel", "migrateOldCsvFiles failed", e)
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

    val isAdmin = preferences.isAdmin
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val autoAiSuggestions = preferences.autoAiSuggestions
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    val settingsTutorialSeen: StateFlow<Boolean?> = preferences.settingsTutorialSeen
        .map { it as Boolean? }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val userContextHidden = preferences.userContextHidden
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

    private val _searchQuery = MutableStateFlow("")
    val searchQuery = _searchQuery.asStateFlow()

    fun setSearchQuery(query: String) {
        _searchQuery.value = query
    }

    val conditionsCount: StateFlow<Int> = conditionRepository.conditions.map { it.size }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val medicationsCount: StateFlow<Int> = medications.map { it.size }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val conditionsAndMedicationsCount: StateFlow<Int> = combine(
        conditionsCount,
        medicationsCount
    ) { c, m -> c + m }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0)

    val connectedAppsCount: StateFlow<Int> = combine(
        healthConnectConnected,
        googleCalendarConnected,
        googleAccountConnected
    ) { hc, cal, google ->
        var count = 0
        if (hc) count++
        if (cal) count++
        if (google) count++
        if (count == 0) 1 else count
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 1)

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

    // Tabs Lab: daily check-in reminder toggle. Default off.
    val checkInReminderEnabled = preferences.checkInReminderEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

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

    fun flushProfilePush() {
        pushContextJob?.cancel()
        viewModelScope.launch {
            syncManager.pushProfileData()
        }
    }

    fun saveUserContext(text: String) {
        viewModelScope.launch { 
            preferences.setUserContext(text)
            preferences.setUserContextLastUpdate(System.currentTimeMillis())
            
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

    val userConditionsList = conditionRepository.conditions.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5000),
        emptyList()
    )

    val userConditionsStr = conditionRepository.conditions.map { list: List<String> ->
        kotlinx.serialization.json.Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(kotlinx.serialization.serializer<String>()), list)
    }.stateIn(
        viewModelScope,
        SharingStarted.Lazily,
        "[]"
    )

    fun addUserCondition(condition: String) {
        viewModelScope.launch {
            conditionRepository.addCondition(condition)
        }
    }

    fun removeUserCondition(condition: String) {
        viewModelScope.launch {
            conditionRepository.removeCondition(condition)
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
                    logRepository.setProcessError(com.notel.notel.util.FriendlyErrors.forBackendError(TAG, it, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN).banner)
                }
            } catch (e: Exception) {
                logRepository.setProcessError(com.notel.notel.util.FriendlyErrors.forBackendError(TAG, e, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN).banner)
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
                    logRepository.setProcessError(com.notel.notel.util.FriendlyErrors.forBackendError(TAG, it, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN).banner)
                }
            } catch (e: Exception) {
                logRepository.setProcessError(com.notel.notel.util.FriendlyErrors.forBackendError(TAG, e, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN).banner)
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

    private val _reportGenerationState = MutableStateFlow<com.notel.notel.ui.state.ReportGenerationState>(com.notel.notel.ui.state.ReportGenerationState.Idle)
    val reportGenerationState = _reportGenerationState.asStateFlow()

    private var reportJob: kotlinx.coroutines.Job? = null

    /**
     * Phase 1 (WS-A/WS-F): the screen passes a [ReportRange] and [ReportFocus];
     * both are threaded screen -> collector -> GeminiService -> snapshot, and
     * that ONE snapshot feeds the AI narrative and the PDF.
     */
    fun generateProfessionalReport(
        range: com.notel.notel.data.model.ReportRange = com.notel.notel.data.model.ReportRange.Last30Days,
        focus: com.notel.notel.data.model.ReportFocus = com.notel.notel.data.model.ReportFocus.Health,
        customCategoryIds: Set<Int> = emptySet(),
        forceRawFallback: Boolean = false
    ) {
        reportJob?.cancel()
        reportJob = viewModelScope.launch {
            try {
                val cats = categories.value
                if (forceRawFallback) {
                    _reportGenerationState.value = com.notel.notel.ui.state.ReportGenerationState.CollectingData("Collecting patient data for Raw Data report...")
                    val snapshot = logRepository.clinicalReportDataCollector.collectReportData(
                        allCategories = cats,
                        range = range,
                        focus = focus,
                        customCategoryIds = customCategoryIds
                    )
                    _reportGenerationState.value = com.notel.notel.ui.state.ReportGenerationState.RenderingPdf("Rendering Raw Data PDF...")
                    val result = reportGenerator.generateReport(snapshot, aiSummary = null, isRawFallback = true)
                    val file = result?.file
                    if (file != null) {
                        _reportGenerationState.value = com.notel.notel.ui.state.ReportGenerationState.Ready(file, isRawFallback = true, downloadsUri = result.downloadsUri)
                        com.notel.notel.util.NotificationHelper(context).showReportReady(file)
                    } else {
                        _reportGenerationState.value = com.notel.notel.ui.state.ReportGenerationState.Failed("Failed generating Raw Data report file.")
                    }
                } else {
                    logRepository.generateProfessionalReportWithSnapshot(
                        categories = cats,
                        reportGenerator = reportGenerator,
                        range = range,
                        focus = focus,
                        customCategoryIds = customCategoryIds,
                        onStateUpdate = { state ->
                            _reportGenerationState.value = state
                            if (state is com.notel.notel.ui.state.ReportGenerationState.Ready) {
                                com.notel.notel.util.NotificationHelper(context).showReportReady(state.file)
                            }
                        }
                    )
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                _reportGenerationState.value = com.notel.notel.ui.state.ReportGenerationState.Cancelled
            } catch (e: Exception) {
                _reportGenerationState.value = com.notel.notel.ui.state.ReportGenerationState.Failed(com.notel.notel.util.FriendlyErrors.forBackendError(TAG, e, com.notel.notel.util.FriendlyErrors.Kind.EXPORT).banner, allowRawFallback = true)
            }
        }
    }

    @Deprecated("Use generateProfessionalReport(range, focus, customCategoryIds)")
    fun generateProfessionalReport(
        last30DaysOnly: Boolean = false,
        forceRawFallback: Boolean = false,
        // Playground: Progress Reports type picker. Optional override for which
        // categories feed the report. Null keeps the legacy all-categories path.
        categoriesOverride: List<com.notel.notel.data.local.entity.Category>? = null
    ) {
        generateProfessionalReport(
            range = if (last30DaysOnly) com.notel.notel.data.model.ReportRange.Last30Days
            else com.notel.notel.data.model.ReportRange.AllTime,
            // Legacy path never filtered entries by focus; Custom over every
            // category (or the override list) preserves that exactly.
            focus = com.notel.notel.data.model.ReportFocus.Custom(""),
            customCategoryIds = (categoriesOverride ?: categories.value).map { it.id }.toSet(),
            forceRawFallback = forceRawFallback
        )
    }

    fun cancelReportGeneration() {
        reportJob?.cancel()
        reportJob = null
        _reportGenerationState.value = com.notel.notel.ui.state.ReportGenerationState.Cancelled
        logRepository.resetGeneratedReport()
    }

    fun resetReportGenerationState() {
        _reportGenerationState.value = com.notel.notel.ui.state.ReportGenerationState.Idle
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

    /**
     * Tabs Lab: persists the check-in reminder toggle and arms/cancels the
     * 4:00 AM alarm to match. Called only after the notification permission
     * flow completes (see SettingsScreen).
     */
    fun setCheckInReminderEnabled(enabled: Boolean) {
        viewModelScope.launch {
            preferences.setCheckInReminderEnabled(enabled)
            if (enabled) {
                com.notel.notel.notifications.EnergyCheckInReminderScheduler.schedule(context)
            } else {
                com.notel.notel.notifications.EnergyCheckInReminderScheduler.cancel(context)
            }
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
            
            // Sync with Room SQLite DB
            val dbMed = com.notel.notel.data.local.entity.Medication(
                name = name.trim(),
                dose = "As prescribed",
                frequency = "Daily",
                isArchived = !isPresent,
                startedDate = startDate.trim().ifEmpty { null },
                endedDate = if (!isPresent) endDate.trim().ifEmpty { null } else null
            )
            database.medicationDao().insertMedication(dbMed)
            
            syncManager.pushProfileData()
        }
    }

    fun deleteMedication(id: String) {
        viewModelScope.launch {
            val medToDelete = medications.value.find { it.id == id }
            val current = medications.value.filter { it.id != id }
            preferences.setMedications(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(Medication.serializer()), current))
            
            // Sync deletion with Room SQLite DB
            medToDelete?.let {
                database.medicationDao().deleteMedicationByName(it.name)
            }
            
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
                            
                            // Sync extraction with Room SQLite DB
                            parsed.forEach { item ->
                                val dbMed = com.notel.notel.data.local.entity.Medication(
                                    name = item.name.trim(),
                                    dose = "As prescribed",
                                    frequency = "Daily",
                                    isArchived = !item.isPresent,
                                    startedDate = item.startDate.trim().ifEmpty { null },
                                    endedDate = if (!item.isPresent) item.endDate.trim().ifEmpty { null } else null
                                )
                                database.medicationDao().insertMedication(dbMed)
                            }
                            
                            syncManager.pushProfileData()
                            
                            onResult(parsed)
                        } catch (e: Exception) {
                            onError(com.notel.notel.util.FriendlyErrors.forBackendError(TAG, e, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN).banner)
                        }
                    },
                    onFailure = { err ->
                        onError(com.notel.notel.util.FriendlyErrors.forBackendError(TAG, err, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN).banner)
                    }
                )
            } catch (e: Exception) {
                onError(com.notel.notel.util.FriendlyErrors.forBackendError(TAG, e, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN).banner)
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

    fun restartOnboarding(onLogout: () -> Unit) {
        viewModelScope.launch {
            try {
                // Read refresh token before clearing credentials
                val rfToken = preferences.refreshToken.first()
                if (rfToken.isNotEmpty()) {
                    try {
                        tabsApi.logout(LogoutRequest(rfToken))
                    } catch (_: Exception) {}
                }
            } catch (_: Exception) {}

            try {
                // 1. Delete account from server (removes user row + all server-side data via CASCADE)
                logRepository.deleteAccountData()
            } catch (_: Exception) {
                // Even if server call fails, still wipe locally so the user is fully logged out
            }

            // 2. Clear all local credentials and preferences
            preferences.clearCredentials()

            // 3. Clear memory caches
            logRepository.clearCache()
            habitRepository.clearCache()

            // 4. Wipe Room database
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                try {
                    val db = database.openHelper.writableDatabase
                    db.beginTransaction()
                    try {
                        db.execSQL("DELETE FROM user_list_items")
                        db.execSQL("DELETE FROM user_lists")
                        db.execSQL("DELETE FROM log_entries")
                        db.execSQL("DELETE FROM reminders")
                        db.execSQL("DELETE FROM coach_messages")
                        db.execSQL("DELETE FROM coach_sessions")
                        db.execSQL("DELETE FROM medications")
                        db.execSQL("DELETE FROM medication_side_effect_cache")
                        db.execSQL("DELETE FROM knowledge_documents")
                        db.execSQL("DELETE FROM categories")
                        db.setTransactionSuccessful()
                    } finally {
                        db.endTransaction()
                    }
                } catch (_: Exception) {
                    database.clearAllTables()
                }
                // Re-seed default categories for the next user
                database.categoryDao().insertAll(com.notel.notel.data.local.DefaultCategories.all)
            }

            // 5. Navigate to login screen (same callback as logout)
            onLogout()
        }
    }

    private val _logoutError = MutableStateFlow<String?>(null)
    val logoutError = _logoutError.asStateFlow()

    private val _isLoggingOut = MutableStateFlow(false)
    val isLoggingOut = _isLoggingOut.asStateFlow()

    fun clearLogoutError() { _logoutError.value = null }

    fun logout(onLogout: () -> Unit) {
        _isLoggingOut.value = true
        _logoutError.value = null
        viewModelScope.launch {
            // 0. Push ALL local data to the server BEFORE wiping anything
            // Run all three pushes in parallel to minimize wait time
            var syncSuccess = true
            try {
                val (profilePushed, entriesPushed, categoriesPushed) = coroutineScope {
                    val profileDeferred = async { syncManager.pushProfileData(skipHealthConnect = true) }
                    val entriesDeferred = async { syncManager.pushEntries() }
                    val categoriesDeferred = async { syncManager.pushCategories() }
                    Triple(profileDeferred.await(), entriesDeferred.await(), categoriesDeferred.await())
                }

                // Verify the sync pushes actually reached the server
                if (!profilePushed || !entriesPushed || !categoriesPushed) {
                    syncSuccess = false
                }
            } catch (e: Exception) {
                syncSuccess = false
            }

            if (!syncSuccess) {
                // If sync failed, block account wipe to prevent un-synced data deletion
                _logoutError.value = "Unable to sync unsynced records to cloud. Logout cancelled to prevent data loss. Please check your internet connection."
                _isLoggingOut.value = false
                return@launch
            }

            // 1. Call server logout to revoke refresh token
            try {
                val rfToken = preferences.refreshToken.first()
                if (rfToken.isNotEmpty()) {
                    tabsApi.logout(LogoutRequest(rfToken))
                }
            } catch (_: Exception) {
                // If network/logout call fails, proceed with local session cleanup since sync already succeeded
            }

            // 2. Clear DataStore preferences (credentials, tokens, AI context, etc.)
            preferences.clearCredentials()

            // 2b. Clear memory caches of Singletons to prevent cross-account leakage
            logRepository.clearCache()
            habitRepository.clearCache()
            
            // 2. Clear Room database (Logs, Insights, Custom Categories)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                try {
                    val db = database.openHelper.writableDatabase
                    db.beginTransaction()
                    try {
                        db.execSQL("DELETE FROM user_list_items")
                        db.execSQL("DELETE FROM user_lists")
                        db.execSQL("DELETE FROM log_entries")
                        db.execSQL("DELETE FROM reminders")
                        db.execSQL("DELETE FROM coach_messages")
                        db.execSQL("DELETE FROM coach_sessions")
                        db.execSQL("DELETE FROM medications")
                        db.execSQL("DELETE FROM medication_side_effect_cache")
                        db.execSQL("DELETE FROM knowledge_documents")
                        db.execSQL("DELETE FROM categories")
                        db.setTransactionSuccessful()
                    } finally {
                        db.endTransaction()
                    }
                } catch (e: Exception) {
                    database.clearAllTables()
                }
                
                // 3. Re-seed default categories so the UI isn't empty/broken for next user
                database.categoryDao().insertAll(com.notel.notel.data.local.DefaultCategories.all)
            }
            
            _isLoggingOut.value = false
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

    // Developer Terminal: one test button per notification the app can send.
    // Each fires its notification immediately on demand.

    fun testCheckInReminderNotification(context: android.content.Context) {
        viewModelScope.launch {
            // Tabs Lab: the exact notification the 4:00 AM receiver posts.
            com.notel.notel.util.NotificationHelper(context).showCheckInReminder()
        }
    }

    fun testAppointmentReminderNotification(context: android.content.Context) {
        viewModelScope.launch {
            // Tabs Lab: the exact notification the day-before appointment receiver posts.
            com.notel.notel.util.NotificationHelper(context)
                .showAppointmentReminder("Health", "Oct 15")
        }
    }

    fun testMiddayBodyLoadNotification(context: android.content.Context) {
        viewModelScope.launch {
            com.notel.notel.util.NotificationHelper(context).showMidDayBodyLoadRefresh()
        }
    }

    fun testBodyLoadUpdateNotification(context: android.content.Context) {
        viewModelScope.launch {
            // Representative score for the preview; the real one passes the computed score.
            com.notel.notel.util.NotificationHelper(context).showBodyLoadUpdate(72)
        }
    }

    fun testEventNotification(context: android.content.Context) {
        viewModelScope.launch {
            com.notel.notel.util.NotificationHelper(context).showEventNotification("Test Event")
        }
    }

    fun testGraphReportNotification(context: android.content.Context) {
        viewModelScope.launch {
            com.notel.notel.util.NotificationHelper(context).showGraphReportNotification(null)
        }
    }

    fun testReportReadyNotification(context: android.content.Context) {
        viewModelScope.launch {
            // Placeholder PDF in cache so the share action has a valid file to point at.
            val file = java.io.File(context.cacheDir, "test_report.pdf").apply {
                if (!exists()) writeBytes("%PDF-1.4\n%Test placeholder\n".toByteArray())
            }
            com.notel.notel.util.NotificationHelper(context).showReportReady(file)
        }
    }

    fun testCsvReadyNotification(context: android.content.Context) {
        viewModelScope.launch {
            // Placeholder CSV in cache so the share action has a valid file to point at.
            val file = java.io.File(context.cacheDir, "test_export.csv").apply {
                if (!exists()) writeText("date,value\n2026-09-30,test\n")
            }
            com.notel.notel.util.NotificationHelper(context).showCsvReady(file)
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
                    android.widget.Toast.makeText(context, "You are not logged in. Please sign in to sync.", android.widget.Toast.LENGTH_SHORT).show()
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
                        "Could not recover your account data. Please check your internet connection.",
                        android.widget.Toast.LENGTH_LONG
                    ).show()
                }
            } catch (e: Exception) {
                android.widget.Toast.makeText(
                    context,
                    com.notel.notel.util.FriendlyErrors.forBackendError(TAG, e, com.notel.notel.util.FriendlyErrors.Kind.LOAD).banner,
                    android.widget.Toast.LENGTH_LONG
                ).show()
                _syncError.emit(com.notel.notel.util.FriendlyErrors.forBackendError(TAG, e, com.notel.notel.util.FriendlyErrors.Kind.LOAD).banner)
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
                    android.widget.Toast.makeText(context, "You are not logged in. Please sign in to sync.", android.widget.Toast.LENGTH_SHORT).show()
                    return@launch
                }
                syncManager.syncAllData()
                android.widget.Toast.makeText(context, "Sync complete!", android.widget.Toast.LENGTH_SHORT).show()
            } catch (e: Exception) {
                android.widget.Toast.makeText(
                    context,
                    com.notel.notel.util.FriendlyErrors.syncOneLiner(TAG, e),
                    android.widget.Toast.LENGTH_LONG
                ).show()
                _syncError.emit(com.notel.notel.util.FriendlyErrors.syncOneLiner(TAG, e))
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
                    android.util.Log.e(TAG, "updateNickname failed: " + updateRes.code()); onResult(false, com.notel.notel.util.FriendlyErrors.forBackendError(TAG, null, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN).banner)
                }
            } catch (e: Exception) {
                onResult(false, com.notel.notel.util.FriendlyErrors.forBackendError(TAG, e, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN).banner)
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
                    onError(com.notel.notel.util.FriendlyErrors.forBackendError(
                        TAG, error, com.notel.notel.util.FriendlyErrors.Kind.UNKNOWN
                    ).banner)
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
    val id: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    val startDate: String = "",
    val endDate: String = "",
    val isPresent: Boolean = false,
    val dose: String = "As prescribed",
    val frequency: String = "Daily",
    val updatedAt: Long = System.currentTimeMillis(),
    val isDeleted: Boolean = false
)

