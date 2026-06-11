package com.notel.notel.data.sync

import android.content.Context
import android.util.Log
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.local.entity.UserListItem
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.notifications.ReminderScheduler
import com.notel.notel.data.remote.*
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

@Singleton
class SyncManager @Inject constructor(
    private val jotApi: JotApi,
    private val logEntryDao: LogEntryDao,
    private val categoryDao: CategoryDao,
    private val knowledgeDocumentDao: com.notel.notel.data.local.dao.KnowledgeDocumentDao,
    private val coachSessionDao: com.notel.notel.data.local.dao.CoachSessionDao,
    private val coachMessageDao: com.notel.notel.data.local.dao.CoachMessageDao,
    private val userListDao: com.notel.notel.data.local.dao.UserListDao,
    private val reminderDao: com.notel.notel.data.local.dao.ReminderDao,
    private val habitRepository: com.notel.notel.data.repository.HabitRepository,
    private val preferences: NotelPreferences,
    private val healthConnectManager: com.notel.notel.data.healthconnect.HealthConnectManager,
    @ApplicationContext private val context: Context
) {
    private val tag = "SyncManager"
    private val syncMutex = Mutex()
    private var logCallback: ((String) -> Unit)? = null

    fun setLogCallback(callback: (String) -> Unit) {
        logCallback = callback
    }

    private fun log(message: String) {
        Log.d(tag, message)
        logCallback?.invoke(message)
    }

    suspend fun syncAllData() = withContext(Dispatchers.IO) {
        if (!syncMutex.tryLock()) {
            Log.d(tag, "Sync already in progress. Skipping duplicate request.")
            return@withContext
        }
        try {
            if (!preferences.loggedIn.first()) return@withContext
            
            Log.d(tag, "Full sync initiated...")
            
            // 1. Snapshot Recovery (Server -> Local, then Local -> Server)
            // Pull cloud data first to recover any existing server state (e.g. after a database wipe or app update)
            val pullSuccess = pullAllData()
            if (!pullSuccess) {
                Log.w(tag, "Sync pull failed. Aborting sync cycle to prevent local data loss.")
                return@withContext
            }

            // Only push profile data if the user has completed onboarding locally.
            if (preferences.onboardingComplete.first()) {
                val profilePushSuccess = pushProfileData()
                if (!profilePushSuccess) {
                    Log.e(tag, "Profile push failed, aborting full sync to prevent local data loss.")
                    return@withContext
                }
            }
            val categories = categoryDao.getAllCategories().first()
            if (categories.isNotEmpty()) {
                val categoryDtos = categories.map {
                    CategoryDtoModel(it.id, it.name, it.icon, it.colorHex, it.isDefault, it.sortOrder)
                }
                val catRes = jotApi.syncCategories(SyncCategoriesRequest(categoryDtos))
                if (!catRes.isSuccessful) {
                    Log.e(tag, "Categories sync failed, aborting full sync: ${catRes.errorBody()?.string()}")
                    return@withContext
                }
            }

            val entries = logEntryDao.getAllEntries().first()
            if (entries.isNotEmpty()) {
                val entryDtos = entries.map {
                    LogEntryDtoModel(it.id, it.categoryId, it.body, it.chips, it.manualText, it.timestamp)
                }
                val entryRes = jotApi.syncEntries(SyncEntriesRequest(entryDtos))
                if (!entryRes.isSuccessful) {
                    Log.e(tag, "Entries sync failed, aborting full sync: ${entryRes.errorBody()?.string()}")
                    return@withContext
                }
            }

            syncDocuments()
            syncCoachSessions()
            syncCoachMessages()

            // Generate and cache historical biometrics insights synchronously before pushing
            generateHistoricalBiometricsInsights()

            // Push AI Insights (including BodyLoad scores) to the server
            val insightsStr = preferences.aiInsights.first()
            if (insightsStr.isNotBlank()) {
                val localInsights = try {
                    Json.decodeFromString<List<com.notel.notel.data.local.entity.AiInsight>>(insightsStr)
                } catch (e: Exception) { emptyList() }
                
                if (localInsights.isNotEmpty()) {
                    val insightDtos = localInsights.map {
                        InsightDtoModel(it.id, it.text, it.type, it.timestamp)
                    }
                    val insightRes = jotApi.syncInsights(SyncInsightsRequest(insightDtos))
                    if (!insightRes.isSuccessful) {
                        Log.e(tag, "Insights sync failed: ${insightRes.errorBody()?.string()}")
                    }
                }
            }

            // Profile is handled at the start for optimistic local updates.
            preferences.setLastSyncTime(System.currentTimeMillis())
            Log.d(tag, "Sync cycle complete!")
        } catch (e: Exception) {
            Log.e(tag, "Sync cycle failed: ${e.message}")
        } finally {
            syncMutex.unlock()
        }
    }

    suspend fun calculateWeeklyScore(): Int = withContext(Dispatchers.IO) {
        try {
            // Reset to Sunday 12:00 AM
            val cal = java.util.Calendar.getInstance()
            cal.set(java.util.Calendar.DAY_OF_WEEK, java.util.Calendar.SUNDAY)
            cal.set(java.util.Calendar.HOUR_OF_DAY, 0)
            cal.set(java.util.Calendar.MINUTE, 0)
            cal.set(java.util.Calendar.SECOND, 0)
            cal.set(java.util.Calendar.MILLISECOND, 0)
            val startOfWeek = cal.timeInMillis

            // Get date strings for the week
            val dates = mutableListOf<String>()
            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
            val todayStr = sdf.format(java.util.Date())
            
            val tempCal = java.util.Calendar.getInstance()
            tempCal.timeInMillis = startOfWeek
            var dateStr = sdf.format(tempCal.time)
            dates.add(dateStr)
            while (dateStr != todayStr && dates.size < 7) {
                tempCal.add(java.util.Calendar.DAY_OF_YEAR, 1)
                dateStr = sdf.format(tempCal.time)
                dates.add(dateStr)
            }

            // Fetch logs for the week
            val weeklyEntries = logEntryDao.getRecentEntriesInRange(startOfWeek, System.currentTimeMillis())
            val jotsByDate = weeklyEntries.groupBy {
                sdf.format(java.util.Date(it.timestamp))
            }

            // Fetch Biomarker Lists
            val json = Json { ignoreUnknownKeys = true }
            
            val hrStr = preferences.historicalHeartRate.first()
            val hrMap = try {
                if (hrStr.isNotBlank()) json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(hrStr).associate { it.date to it.value.toInt() } else emptyMap()
            } catch(e: Exception) { emptyMap() }

            val sleepStr = preferences.historicalSleep.first()
            val sleepMap = try {
                if (sleepStr.isNotBlank()) json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(sleepStr).associate { it.date to it.value.toInt() } else emptyMap()
            } catch(e: Exception) { emptyMap() }

            val calStr = preferences.historicalCalories.first()
            val calMap = try {
                if (calStr.isNotBlank()) json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(calStr).associate { it.date to it.value.toInt() } else emptyMap()
            } catch(e: Exception) { emptyMap() }

            var totalScore = 0

            // 1. Streak Points: Streak * 25
            val streak = preferences.currentStreak.first()
            totalScore += streak * 25

            // 2. Iterate each day of the week to sum up points
            dates.forEach { d ->
                // A. Jots: 100 pts per Jot, max 3 per day (300 max)
                val dailyJots = jotsByDate[d]?.size ?: 0
                totalScore += minOf(3, dailyJots) * 100

                // B. Calories: Total Calories / 20, max 200 pts (4000 cap)
                val dailyCal = calMap[d] ?: 0
                if (dailyCal > 0) {
                    totalScore += minOf(200, dailyCal / 20)
                }

                // C. Sleep: Sleep minutes / 6. If sleep minutes is in [420, 540], add +100 bonus
                val sleepMins = sleepMap[d] ?: 0
                if (sleepMins > 0) {
                    totalScore += sleepMins / 6
                    if (sleepMins in 420..540) {
                        totalScore += 100 // Sweet Spot rest bonus
                    }
                }

                // D. Avg HR: 50 points daily for active tracking + 100 points for healthy range [55, 85]
                val avgHr = hrMap[d] ?: 0
                if (avgHr > 0) {
                    totalScore += 50 // Tracking active points
                    if (avgHr in 55..85) {
                        totalScore += 100 // Healthy range bonus
                    }
                }
            }

            totalScore
        } catch (e: Exception) {
            0
        }
    }

    var lastProfilePushError: String? = null
        private set

    suspend fun pushProfileData(): Boolean = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext false
            
            // Serialize User Lists
            val localLists = userListDao.getAllLists().first()
            val syncDtos = localLists.map { list ->
                val items = userListDao.getItemsForList(list.id).first().map { it.text }
                UserListSyncDto(list.name, items)
            }
            val userListsJson = Json.encodeToString(syncDtos)

            // Serialize Reminders
            val localReminders = reminderDao.getAllReminders().first()
            val remindersJson = Json.encodeToString(localReminders)

            val weeklyScoreValue = calculateWeeklyScore()
            preferences.setWeeklyScore(weeklyScoreValue)

            // Compute today's shared metrics
            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
            val todayStr = sdf.format(java.util.Date())
            val json2 = Json { ignoreUnknownKeys = true }

            val hrStr2 = preferences.historicalHeartRate.first()
            val hrMap2 = try {
                if (hrStr2.isNotBlank()) json2.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(hrStr2).associate { it.date to it.value.toInt() } else emptyMap()
            } catch(e: Exception) { emptyMap() }

            val sleepStr2 = preferences.historicalSleep.first()
            val sleepMap2 = try {
                if (sleepStr2.isNotBlank()) json2.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(sleepStr2).associate { it.date to it.value.toInt() } else emptyMap()
            } catch(e: Exception) { emptyMap() }

            var todaySleep = sleepMap2[todayStr] ?: 0
            var todayHr = hrMap2[todayStr] ?: 0
            var todaySpikeCount = 0

            if (healthConnectManager.hasBasicPermissions()) {
                try {
                    val liveSleep = healthConnectManager.readSleepSession(todayStr)
                    if (liveSleep != null) {
                        todaySleep = liveSleep.minutesAsleep
                    }
                    val liveRhr = healthConnectManager.readRestingHeartRate(todayStr)
                    val liveHr = if (liveRhr != null && liveRhr > 0) {
                        liveRhr
                    } else {
                        val avg = healthConnectManager.readHeartRateAverage(todayStr)
                        if (avg > 0) avg else 0
                    }
                    if (liveHr > 0) {
                        todayHr = liveHr
                    }
                    val spikes = healthConnectManager.readHistoricalHeartRateWithSpikes(1)
                    val todaySpikeObj = spikes.find { it.date == todayStr }
                    if (todaySpikeObj != null) {
                        todaySpikeCount = todaySpikeObj.spikeCount
                    }
                } catch (e: Exception) {
                    Log.e(tag, "Failed to read live Health Connect data for today: ${e.message}")
                }
            } else {
                val spikesStr = preferences.historicalHrSpikes.first()
                val spikesList = try {
                    if (spikesStr.isNotBlank()) json2.decodeFromString<List<com.notel.notel.data.healthconnect.DailyHeartRateSummary>>(spikesStr) else emptyList()
                } catch(e: Exception) { emptyList() }
                todaySpikeCount = spikesList.find { it.date == todayStr }?.spikeCount ?: 0
            }

            // Sleep debt computation
            val sleepHistoryPairs = sleepMap2.toMutableMap()
            if (todaySleep > 0) {
                sleepHistoryPairs[todayStr] = todaySleep
            }
            val todaySleepDebtVal = calculateDebtAtDate(todayStr, sleepHistoryPairs.toList())
            val todayScoreVal = weeklyScoreValue

            preferences.setTodaySleepMins(todaySleep)
            preferences.setTodayAvgHrShared(todayHr)
            preferences.setTodayScore(todayScoreVal)
            preferences.setTodaySpikes(todaySpikeCount)
            preferences.setTodaySleepDebt(todaySleepDebtVal)

            val response = jotApi.syncProfile(
                SyncProfileRequest(
                    userContext = preferences.userContext.first(),
                    knowledgeBase = preferences.knowledgeBase.first(),
                    professionalUpdates = preferences.professionalUpdates.first(),
                    processedFiles = preferences.processedFiles.first(),
                    loggedDays = preferences.loggedDays.first(),
                    age = preferences.userAge.first(),
                    heightCm = preferences.userHeight.first() * 2.54f,
                    weightKg = preferences.userWeight.first() / 2.20462f,
                    gender = preferences.userGender.first(),
                    onboardingComplete = preferences.onboardingComplete.first(),
                    autoAiSuggestions = preferences.autoAiSuggestions.first(),
                    eventCounters = preferences.eventCounters.first(),
                    counterHistory = preferences.counterHistory.first(),
                    redditSubreddits = preferences.redditSubreddits.first(),
                    redditSummaries = preferences.redditSummaries.first(),
                    currentStreak = preferences.currentStreak.first(),
                    bestStreak = preferences.bestStreak.first(),
                    userLists = userListsJson,
                    focusState = preferences.focusState.first().let { if (it.isBlank()) null else it },
                    reminders = remindersJson,
                    weeklyScore = weeklyScoreValue,
                    shareDataWithFriends = preferences.shareDataWithFriends.first(),
                    todaySleepMins = todaySleep,
                    todayAvgHr = todayHr,
                    todayScore = todayScoreVal,
                    todaySpikes = todaySpikeCount,
                    todaySleepDebt = todaySleepDebtVal
                )
            )
            if (response.isSuccessful) {
                lastProfilePushError = null
                preferences.setLastSyncTime(System.currentTimeMillis())
                true
            } else {
                val errStr = response.errorBody()?.string() ?: "Empty body"
                lastProfilePushError = "HTTP ${response.code()}: $errStr"
                Log.e(tag, "pushProfileData failed: $lastProfilePushError")
                false
            }
        } catch (e: Exception) {
            lastProfilePushError = e.message ?: e.toString()
            Log.e(tag, "pushProfileData failed: $lastProfilePushError")
            false
        }
    }

    suspend fun pushEntries(): Boolean = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext false
            val entries = logEntryDao.getAllEntries().first()
            if (entries.isNotEmpty()) {
                val entryDtos = entries.map {
                    LogEntryDtoModel(it.id, it.categoryId, it.body, it.chips, it.manualText, it.timestamp)
                }
                val response = jotApi.syncEntries(SyncEntriesRequest(entryDtos))
                response.isSuccessful
            } else {
                true
            }
        } catch (e: Exception) {
            Log.e(tag, "pushEntries failed: ${e.message}")
            false
        }
    }

    suspend fun pushCategories(): Boolean = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext false
            val categories = categoryDao.getAllCategories().first()
            if (categories.isNotEmpty()) {
                val categoryDtos = categories.map {
                    CategoryDtoModel(it.id, it.name, it.icon, it.colorHex, it.isDefault, it.sortOrder)
                }
                val response = jotApi.syncCategories(SyncCategoriesRequest(categoryDtos))
                response.isSuccessful
            } else {
                true
            }
        } catch (e: Exception) {
            Log.e(tag, "pushCategories failed: ${e.message}")
            false
        }
    }
    
    suspend fun deleteCategoryRemote(categoryId: Int) = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext
            jotApi.deleteRemoteCategory(categoryId)
        } catch (e: Exception) {
            Log.e(tag, "deleteCategoryRemote failed: ${e.message}")
        }
    }


    suspend fun pullAllData(): Boolean = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext false
            Log.d(tag, "Contacting account cloud...")
            
            val response = withTimeoutOrNull(15000L) {
                jotApi.pullData()
            }
            
            if (response == null) {
                log("Cloud Error: Reachable server not found (15s timeout)")
                return@withContext false
            }

            val body = response.body()
            if (response.isSuccessful && body != null) {
                Log.d(tag, "Cloud data received!")
                
                // Track if we were empty before this.
                val localLogCount = logEntryDao.countEntries()
                
                // Track counts for the user feedback toast
                val logsFound = body.entries.size
                val categoriesFound = body.categories.size
                
                // IMPORTANT SENSITIVITY: If data exists, onboarding is complete and they don't need the tutorial
                if (logsFound > 0 || categoriesFound > 0) {
                    preferences.setOnboardingComplete(true)
                    preferences.setSettingsTutorialSeen(true)
                }

                // A. Restore Categories FIRST
                if (categoriesFound > 0) {
                    val catEntities = body.categories.map { 
                        com.notel.notel.data.local.entity.Category(
                            id = it.id, 
                            name = it.name, 
                            icon = it.icon ?: "circle", 
                            colorHex = it.colorHex ?: "#CCCCCC", 
                            isDefault = it.isDefault, 
                            sortOrder = it.sortOrder
                        ) 
                    }
                    categoryDao.insertAll(catEntities)
                }

                // B. Restore Logs
                if (logsFound > 0) {
                    val entryEntities = body.entries.map { 
                        com.notel.notel.data.local.entity.LogEntry(
                            id = it.id, 
                            timestamp = it.timestamp,
                            categoryId = it.categoryId, 
                            body = it.body, 
                            chips = it.chips, 
                            manualText = it.manualText
                        ) 
                    }
                    logEntryDao.insertAll(entryEntities)
                }

                // Restore User Nickname and Unique Tag
                body.nickname?.let { if (it.isNotBlank()) preferences.setUserNickname(it) }
                body.tag?.let { if (it.isNotBlank()) preferences.setUserTag(it) }
                
                // C. Restore AI Context/Doctor's Notes
                body.profile?.let { profile ->
                    profile.userContext?.let { if (it.isNotBlank()) preferences.setUserContext(it) }
                    profile.knowledgeBase?.let { if (it.isNotBlank()) preferences.setKnowledgeBase(it) }
                    profile.professionalUpdates?.let { if (it.isNotBlank()) preferences.setProfessionalUpdates(it) }
                    profile.processedFiles?.let { if (it.isNotBlank()) preferences.setProcessedFiles(it) }
                    profile.loggedDays?.let { if (it.isNotBlank()) preferences.setLoggedDays(it) }
                    profile.age?.let { preferences.setUserAge(it) }
                    profile.heightCm?.let { preferences.setUserHeight(it / 2.54f) } // convert cm to inches
                    profile.weightKg?.let { preferences.setUserWeight(it * 2.20462f) } // convert kg to lbs
                    profile.gender?.let { preferences.setUserGender(it) }
                    profile.onboardingComplete?.let { 
                        if (it) {
                            preferences.setOnboardingComplete(true)
                            preferences.setCupTheorySeen(true)
                        }
                    }
                    profile.autoAiSuggestions?.let { preferences.setAutoAiSuggestions(it) }
                    // C. Restore AI Context/Doctor's Notes (with Smarter Merging for counters)
                    profile.eventCounters?.let { serverJson ->
                        if (serverJson.isNotBlank()) {
                            val localJson = preferences.eventCounters.first()
                            val localList = try { if (localJson.isNotBlank()) Json.decodeFromString<List<com.notel.notel.ui.viewmodel.EventCounterDto>>(localJson) else emptyList() } catch(e: Exception) { emptyList() }
                            val serverList = try { Json.decodeFromString<List<com.notel.notel.ui.viewmodel.EventCounterDto>>(serverJson) } catch(e: Exception) { emptyList() }
                            
                            // Merge: Server items update local ones, but we keep local items that aren't on server yet
                            val merged = (localList + serverList).distinctBy { it.id }
                            preferences.setEventCounters(Json.encodeToString(merged))
                        }
                    }
                    profile.counterHistory?.let { serverJson ->
                        if (serverJson.isNotBlank()) {
                            val localJson = preferences.counterHistory.first()
                            val localList = try { if (localJson.isNotBlank()) Json.decodeFromString<List<com.notel.notel.ui.viewmodel.CounterHistoryItem>>(localJson) else emptyList() } catch(e: Exception) { emptyList() }
                            val serverList = try { Json.decodeFromString<List<com.notel.notel.ui.viewmodel.CounterHistoryItem>>(serverJson) } catch(e: Exception) { emptyList() }
                            
                            // Merge history and take latest 20
                            val merged = (localList + serverList).distinctBy { it.name + it.endedAt }.sortedByDescending { it.endedAt }.take(20)
                            preferences.setCounterHistory(Json.encodeToString(merged))
                        }
                    }
                    profile.redditSubreddits?.let { if (it.isNotBlank()) preferences.setRedditSubreddits(it) }
                    profile.redditSummaries?.let { if (it.isNotBlank()) preferences.setRedditSummaries(it) }
                    profile.currentStreak?.let { preferences.setCurrentStreak(it) }
                    profile.bestStreak?.let { preferences.setBestStreak(it) }
                    profile.weeklyScore?.let { preferences.setWeeklyScore(it) }
                    profile.todaySleepMins?.let { preferences.setTodaySleepMins(it) }
                    profile.todayAvgHr?.let { preferences.setTodayAvgHrShared(it) }
                    profile.todayScore?.let { preferences.setTodayScore(it) }
                    profile.todaySpikes?.let { preferences.setTodaySpikes(it) }
                    profile.todaySleepDebt?.let { preferences.setTodaySleepDebt(it) }
                    profile.focusState?.let { serverJson ->
                        if (serverJson.isNotBlank()) {
                            val localJson = preferences.focusState.first()
                            val shouldOverwrite = try {
                                if (localJson.isBlank() || localJson == "{}") {
                                    true
                                } else {
                                    val localHasTests = localJson.contains("\"activeTests\":[{\"")
                                    val serverHasTests = serverJson.contains("\"activeTests\":[{\"")
                                    serverHasTests || !localHasTests
                                }
                            } catch (e: Exception) {
                                true
                            }
                            if (shouldOverwrite) {
                                preferences.setFocusState(serverJson)
                            }
                        }
                    }
                    profile.userLists?.let { serverJson ->
                        if (serverJson.isNotBlank()) {
                            val pulledLists = try { Json.decodeFromString<List<UserListSyncDto>>(serverJson) } catch(e: Exception) { emptyList() }
                            // Only clear and replace if server actually returned lists to restore
                            if (pulledLists.isNotEmpty()) {
                                userListDao.clearAllLists()
                                userListDao.clearAllListItems()
                                pulledLists.forEach { listDto ->
                                    val insertedListId = userListDao.insertList(UserList(name = listDto.name)).toInt()
                                    listDto.items.forEachIndexed { index, text ->
                                        userListDao.insertItem(UserListItem(listId = insertedListId, text = text, sortOrder = index))
                                    }
                                }
                            }
                        }
                    }
                    profile.reminders?.let { serverJson ->
                        if (serverJson.isNotBlank()) {
                            val pulledReminders = try { Json.decodeFromString<List<Reminder>>(serverJson) } catch(e: Exception) { null }
                            // Only clear and replace if server actually returned reminders to restore
                            if (pulledReminders != null && pulledReminders.isNotEmpty()) {
                                // Cancel existing alarms
                                val existing = reminderDao.getAllReminders().first()
                                existing.forEach { ReminderScheduler.cancel(context, it) }

                                // Overwrite local SQLite reminders
                                reminderDao.clearAllReminders()
                                pulledReminders.forEach { reminder ->
                                    reminderDao.insert(reminder)
                                    if (reminder.isEnabled) {
                                        ReminderScheduler.schedule(context, reminder)
                                    }
                                }
                            }
                        }
                    }
                }

                // D. Restore Documents
                if (body.documents.isNotEmpty()) {
                    body.documents.forEach { doc ->
                        val local = knowledgeDocumentDao.getDocumentById(doc.id)
                        if (local == null) {
                            // Fetch content and save
                            try {
                                val dataRes = jotApi.getDocumentData(doc.id)
                                val base64 = dataRes.body()?.result
                                if (base64 != null) {
                                    val bytes = android.util.Base64.decode(base64, android.util.Base64.DEFAULT)
                                    val file = java.io.File(context.filesDir, "knowledge_docs/${doc.id}_${doc.name}")
                                    file.parentFile?.mkdirs()
                                    file.writeBytes(bytes)
                                    
                                    knowledgeDocumentDao.insertDocument(
                                        com.notel.notel.data.local.entity.KnowledgeDocument(
                                            id = doc.id,
                                            name = doc.name,
                                            mimeType = doc.mimeType,
                                            filePath = file.absolutePath,
                                            createdAt = doc.createdAt
                                        )
                                    )
                                }
                            } catch (e: Exception) {
                                Log.e(tag, "Failed to download doc ${doc.id}: ${e.message}")
                            }
                        }
                    }
                }

                // Restore Coach Sessions
                if (body.coachSessions.isNotEmpty()) {
                    val sessionEntities = body.coachSessions.map {
                        com.notel.notel.data.local.entity.CoachSession(it.id, it.title, it.createdAt, it.updatedAt, true)
                    }
                    sessionEntities.forEach { coachSessionDao.insertSession(it) }
                }

                // Restore Coach Messages
                if (body.coachMessages.isNotEmpty()) {
                    val existingSessionIds = (coachSessionDao.getAllSessions().first().map { it.id } + body.coachSessions.map { it.id }).toSet()
                    val messageEntities = body.coachMessages
                        .filter { it.sessionId in existingSessionIds }
                        .map {
                            com.notel.notel.data.local.entity.CoachMessageEntity(it.id, it.sessionId, it.role, it.content, it.timestamp, true)
                        }
                    coachMessageDao.insertMessages(messageEntities)
                }

                // D. Restore AI Results (Productivity)
                if (body.insights.isNotEmpty()) {
                    val localInsightsStr = preferences.aiInsights.first()
                    val localInsights = try {
                        if (localInsightsStr.isNotBlank()) Json.decodeFromString<List<com.notel.notel.data.local.entity.AiInsight>>(localInsightsStr) else emptyList()
                    } catch(e: Exception) { emptyList() }

                    val insightsList = body.insights.map { 
                        com.notel.notel.data.local.entity.AiInsight(it.id, it.text, it.timestamp, it.type)
                    }.toMutableList()

                    // Keep any local today's BodyLoad insight that is not in the server's response
                    localInsights.forEach { localOn ->
                        if (localOn.type == "BodyLoad") {
                            val exists = insightsList.any { it.type == "BodyLoad" && Math.abs(it.timestamp - localOn.timestamp) < 6 * 60 * 60 * 1000 }
                            if (!exists) {
                                insightsList.add(0, localOn)
                            }
                        }
                    }

                    val json = Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(com.notel.notel.data.local.entity.AiInsight.serializer()), insightsList.take(100))
                    preferences.setAiInsights(json)
                }

                if (logsFound > 0 && localLogCount == 0) {
                    log("Account Restored: $logsFound logs & $categoriesFound categories!")
                }
                
                // CRITICAL: Recalculate streak now that we have data
                preferences.updateStreak()

                // CRITICAL: Fetch habits from the server — habits are stored server-side only
                // (not in local SQLite), so they must be re-fetched on every login/sync.
                // This was previously only done in HabitViewModel.init which could run too
                // late (after the UI has already shown empty habits).
                try {
                    habitRepository.fetchHabits()
                } catch (e: Exception) {
                    Log.e(tag, "Habit fetch after pull failed: ${e.message}")
                }

                true
            } else {
                val errorMsg = response.errorBody()?.string() ?: "Unknown Error"
                log("Sync Rejected (HTTP ${response.code()}): $errorMsg")
                false
            }
        } catch (e: Exception) {
            log("Sync Critical Error: ${e.message}")
            false
        }
    }

    private suspend fun syncDocuments() {
        try {
            val docs = knowledgeDocumentDao.getAllDocuments().first()
            if (docs.isNotEmpty()) {
                val dtos = docs.map { doc ->
                    val file = java.io.File(doc.filePath)
                    val base64 = if (file.exists()) {
                        android.util.Base64.encodeToString(file.readBytes(), android.util.Base64.DEFAULT)
                    } else null
                    
                    KnowledgeDocumentDtoModel(
                        id = doc.id,
                        name = doc.name,
                        mimeType = doc.mimeType,
                        fileData = base64,
                        createdAt = doc.createdAt
                    )
                }.filter { it.fileData != null }
                
                if (dtos.isNotEmpty()) {
                    jotApi.syncDocuments(SyncDocumentsRequest(dtos))
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "syncDocuments failed: ${e.message}")
        }
    }

    suspend fun syncCoachSessions() = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext
            val unsynced = coachSessionDao.getUnsyncedSessions()
            if (unsynced.isNotEmpty()) {
                val dtos = unsynced.map {
                    CoachSessionDto(it.id, it.title, it.createdAt, it.updatedAt)
                }
                val response = jotApi.syncCoachSessions(SyncCoachSessionsRequest(dtos))
                if (response.isSuccessful && response.body()?.synced != null) {
                    unsynced.forEach { coachSessionDao.markSynced(it.id) }
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "syncCoachSessions failed: ${e.message}")
        }
    }

    suspend fun syncCoachMessages() = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext
            val unsynced = coachMessageDao.getUnsyncedMessages()
            if (unsynced.isNotEmpty()) {
                val dtos = unsynced.map {
                    CoachMessageDto(it.id, it.sessionId, it.role, it.content, it.timestamp)
                }
                val response = jotApi.syncCoachMessages(SyncCoachMessagesRequest(dtos))
                if (response.isSuccessful && response.body()?.synced != null) {
                    unsynced.forEach { coachMessageDao.markSynced(it.id) }
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "syncCoachMessages failed: ${e.message}")
        }
    }

    private fun calculateDebtAtDate(date: String, history: List<Pair<String, Int>>): Int {
        val targetHours = 8.0
        var runningDebt = 0.0
        val rolling = history
            .filter { it.first <= date }
            .sortedBy { it.first }
            .takeLast(10)
        
        rolling.forEach { (_, mins) ->
            val actualHours = mins / 60.0
            if (actualHours < targetHours) {
                runningDebt += (targetHours - actualHours)
            } else {
                val surplus = actualHours - targetHours
                runningDebt -= Math.min(surplus, 1.5)
            }
            runningDebt = Math.max(0.0, runningDebt)
        }
        return (-runningDebt * 60).toInt()
    }

    private suspend fun generateHistoricalBiometricsInsights() {
        try {
            val isAvailable = healthConnectManager.checkAvailability() == androidx.health.connect.client.HealthConnectClient.SDK_AVAILABLE
            if (!isAvailable) return
            
            val insightsStr = preferences.aiInsights.first()
            val allLocalInsights = try {
                if (insightsStr.isNotBlank()) {
                    Json.decodeFromString<List<com.notel.notel.data.local.entity.AiInsight>>(insightsStr)
                } else emptyList()
            } catch (e: Exception) { emptyList() }

            // Strip old v1-v5 biometrics insights.
            // v6 adds the spikes field. Old entries will be replaced on next sync.
            val strippedInsights = allLocalInsights.filter { insight ->
                insight.type != "Biometrics" || insight.id.endsWith("_v6")
            }

            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).apply {
                timeZone = java.util.TimeZone.getTimeZone(java.time.ZoneId.systemDefault())
            }
            // Only skip dates we already have a correct v6 entry for
            val existingV6Dates = strippedInsights.filter { it.type == "Biometrics" && it.id.endsWith("_v6") }.map {
                sdf.format(java.util.Date(it.timestamp))
            }.toSet()
            
            // Always include the last 7 days in the targetDays list for re-evaluation
            val targetDays = (0..180).map {
                java.time.LocalDate.now().minusDays(it.toLong()).toString()
            }.filter { 
                it !in existingV6Dates || 
                java.time.LocalDate.parse(it).isAfter(java.time.LocalDate.now().minusDays(7))
            }
            
            if (targetDays.isEmpty()) return
            
            val spikesStr = preferences.historicalHrSpikes.first()
            val cachedSpikes = try {
                if (spikesStr.isNotBlank()) {
                    Json { ignoreUnknownKeys = true }.decodeFromString<List<com.notel.notel.data.healthconnect.DailyHeartRateSummary>>(spikesStr)
                } else emptyList()
            } catch (e: Exception) { emptyList() }

            val hrvHistory = try { healthConnectManager.readHeartRateVariability(180) } catch(e: Exception) { emptyList() }
            val sleepHistory = try { healthConnectManager.readHistoricalSleepWithDeep(180) } catch(e: Exception) { emptyList() }
            val calorieHistory = try { healthConnectManager.readHistoricalCalories(180) } catch(e: Exception) { emptyList() }
            val hrHistory = try { healthConnectManager.readHistoricalHeartRate(180) } catch(e: Exception) { emptyList() }
            
            val newInsights = mutableListOf<com.notel.notel.data.local.entity.AiInsight>()
            
            targetDays.forEach { dayStr ->
                val sleepObj = sleepHistory.find { it.date == dayStr }
                val hrvObj = hrvHistory.find { it.first == dayStr }
                val calObj = calorieHistory.find { it.first == dayStr }
                val hrObj = hrHistory.find { it.first == dayStr }
                val spikesObj = cachedSpikes.find { it.date == dayStr }
                
                val sleepMins = sleepObj?.minutesAsleep ?: 0
                val deepSleepMins = sleepObj?.deepMinutes ?: 0
                val hrv = hrvObj?.second ?: 0.0
                val calories = calObj?.second ?: 0
                val avgHr = hrObj?.second ?: 0
                val spikesCount = spikesObj?.spikeCount ?: 0
                
                if (sleepMins > 0 || deepSleepMins > 0 || hrv > 0.0 || calories > 0 || avgHr > 0 || spikesCount > 0) {
                    val localDate = java.time.LocalDate.parse(dayStr)
                    val timestamp = localDate.atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
                    val textJson = """{"sleepMins":$sleepMins,"deepSleepMins":$deepSleepMins,"avgHr":$avgHr,"hrv":$hrv,"calories":$calories,"spikes":$spikesCount}"""
                    newInsights.add(
                        com.notel.notel.data.local.entity.AiInsight(
                            id = "biometrics_${dayStr}_v6",
                            text = textJson,
                            type = "Biometrics",
                            timestamp = timestamp
                        )
                    )
                }
            }
            
            if (newInsights.isNotEmpty()) {
                // Swap order to (newInsights + strippedInsights) so new updates overwrite existing records in distinctBy
                val merged = (newInsights + strippedInsights).distinctBy { it.id }
                preferences.setAiInsights(Json.encodeToString(merged))
                // Push the corrected biometrics to the server directly (no recursive syncAllData)
                val insightDtos = merged.map {
                    com.notel.notel.data.remote.InsightDtoModel(it.id, it.text, it.type, it.timestamp)
                }
                try {
                    jotApi.syncInsights(com.notel.notel.data.remote.SyncInsightsRequest(insightDtos))
                } catch (e: Exception) {
                    Log.e(tag, "Failed to push corrected biometrics to server: ${e.message}")
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "generateHistoricalBiometricsInsights failed: ${e.message}")
        }
    }
}
