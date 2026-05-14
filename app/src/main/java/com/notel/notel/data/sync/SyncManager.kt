package com.notel.notel.data.sync

import android.content.Context
import android.util.Log
import android.widget.Toast
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.*
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
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
    private val preferences: NotelPreferences,
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
        if (syncMutex.isLocked) return@withContext
        syncMutex.withLock {
            try {
                if (!preferences.loggedIn.first()) return@withLock
                
                Log.d(tag, "Full sync initiated...")
                
                // 1. Snapshot Recovery (Local -> Server, then Server -> Local)
                // PREVENT DATA LOSS: Only push profile data if the user has completed onboarding locally.
                // This prevents overwriting the server's data with empty local data on a fresh login.
                if (preferences.onboardingComplete.first()) {
                    pushProfileData()
                }
                val categories = categoryDao.getAllCategories().first()
                if (categories.isNotEmpty()) {
                    val categoryDtos = categories.map {
                        CategoryDtoModel(it.id, it.name, it.icon, it.colorHex, it.isDefault, it.sortOrder)
                    }
                    jotApi.syncCategories(SyncCategoriesRequest(categoryDtos))
                }

                val entries = logEntryDao.getAllEntries().first()
                if (entries.isNotEmpty()) {
                    val entryDtos = entries.map {
                        LogEntryDtoModel(it.id, it.categoryId, it.body, it.chips, it.manualText, it.timestamp)
                    }
                    jotApi.syncEntries(SyncEntriesRequest(entryDtos))
                }

                syncDocuments()

                val pullSuccess = pullAllData()
                if (!pullSuccess) {
                    Log.w(tag, "Sync aborted: Recovery failed. To avoid data loss, we will not push local empty state to server.")
                    return@withLock
                }

                // Profile is handled at the start for optimistic local updates.
                Log.d(tag, "Sync cycle complete!")
            } catch (e: Exception) {
                Log.e(tag, "Sync cycle failed: ${e.message}")
            }
        }
    }

    suspend fun pushProfileData() = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext
            jotApi.syncProfile(
                SyncProfileRequest(
                    userContext = preferences.userContext.first(),
                    knowledgeBase = preferences.knowledgeBase.first(),
                    professionalUpdates = preferences.professionalUpdates.first(),
                    processedFiles = preferences.processedFiles.first(),
                    loggedDays = preferences.loggedDays.first(),
                    onboardingComplete = preferences.onboardingComplete.first(),
                    autoAiSuggestions = preferences.autoAiSuggestions.first(),
                    eventCounters = preferences.eventCounters.first(),
                    counterHistory = preferences.counterHistory.first(),
                    redditSubreddits = preferences.redditSubreddits.first(),
                    redditSummaries = preferences.redditSummaries.first(),
                    currentStreak = preferences.currentStreak.first(),
                    bestStreak = preferences.bestStreak.first()
                )
            )
        } catch (e: Exception) {
            Log.e(tag, "pushProfileData failed: ${e.message}")
        }
    }

    suspend fun pushEntries() = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext
            val entries = logEntryDao.getAllEntries().first()
            if (entries.isNotEmpty()) {
                val entryDtos = entries.map {
                    LogEntryDtoModel(it.id, it.categoryId, it.body, it.chips, it.manualText, it.timestamp)
                }
                jotApi.syncEntries(SyncEntriesRequest(entryDtos))
            }
        } catch (e: Exception) {
            Log.e(tag, "pushEntries failed: ${e.message}")
        }
    }

    suspend fun pushCategories() = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext
            val categories = categoryDao.getAllCategories().first()
            if (categories.isNotEmpty()) {
                val categoryDtos = categories.map {
                    CategoryDtoModel(it.id, it.name, it.icon, it.colorHex, it.isDefault, it.sortOrder)
                }
                jotApi.syncCategories(SyncCategoriesRequest(categoryDtos))
            }
        } catch (e: Exception) {
            Log.e(tag, "pushCategories failed: ${e.message}")
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
                
                // C. Restore AI Context/Doctor's Notes
                body.profile?.let { profile ->
                    profile.userContext?.let { if (it.isNotBlank()) preferences.setUserContext(it) }
                    profile.knowledgeBase?.let { if (it.isNotBlank()) preferences.setKnowledgeBase(it) }
                    profile.professionalUpdates?.let { if (it.isNotBlank()) preferences.setProfessionalUpdates(it) }
                    profile.processedFiles?.let { if (it.isNotBlank()) preferences.setProcessedFiles(it) }
                    profile.loggedDays?.let { if (it.isNotBlank()) preferences.setLoggedDays(it) }
                    profile.age?.let { preferences.setUserAge(it) }
                    profile.heightCm?.let { preferences.setUserHeight(it) }
                    profile.weightKg?.let { preferences.setUserWeight(it) }
                    profile.gender?.let { preferences.setUserGender(it) }
                    profile.onboardingComplete?.let { if (it) preferences.setOnboardingComplete(true) }
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

                // D. Restore AI Results (Productivity)
                if (body.insights.isNotEmpty()) {
                    val insightsList = body.insights.map { 
                        com.notel.notel.data.local.entity.AiInsight(it.id, it.text, it.timestamp, it.type)
                    }
                    val json = Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(com.notel.notel.data.local.entity.AiInsight.serializer()), insightsList)
                    preferences.setAiInsights(json)
                }

                if (logsFound > 0 && localLogCount == 0) {
                    log("Account Restored: $logsFound logs & $categoriesFound categories!")
                }
                true
            } else {
                val errorMsg = response.errorBody()?.string() ?: "Unknown Error"
                log("Sync Rejected (HTTP ${response.code()}): $errorMsg")
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                    android.widget.Toast.makeText(context, "Server: HTTP ${response.code()} — $errorMsg", android.widget.Toast.LENGTH_LONG).show()
                }
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
}
