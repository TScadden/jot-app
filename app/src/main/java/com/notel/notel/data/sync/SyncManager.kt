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
    private val preferences: NotelPreferences,
    @ApplicationContext private val context: Context
) {
    private val tag = "SyncManager"
    private val syncMutex = Mutex()

    suspend fun syncAllData() = withContext(Dispatchers.IO) {
        if (syncMutex.isLocked) return@withContext
        syncMutex.withLock {
            try {
                if (!preferences.loggedIn.first()) return@withLock
                
                Log.d(tag, "Full sync initiated...")
                
                // 1. Snapshot Recovery (Local -> Server, then Server -> Local)
                pushProfileData()
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
                    counterHistory = preferences.counterHistory.first()
                )
            )
        } catch (e: Exception) {
            Log.e(tag, "pushProfileData failed: ${e.message}")
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
                withContext(Dispatchers.Main) { Toast.makeText(context, "Network Error: Could not reach account server (15s timeout)", Toast.LENGTH_LONG).show() }
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
                
                // IMPORTANT SENSITIVITY: If data exists, onboarding is complete
                if (logsFound > 0 || categoriesFound > 0) {
                    preferences.setOnboardingComplete(true)
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
                    profile.eventCounters?.let { if (it.isNotBlank()) preferences.setEventCounters(it) }
                    profile.counterHistory?.let { if (it.isNotBlank()) preferences.setCounterHistory(it) }
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
                    withContext(Dispatchers.Main) { 
                        Toast.makeText(context, "Account Recovery: Restored $logsFound logs and $categoriesFound categories!", Toast.LENGTH_LONG).show() 
                    }
                }
                true
            } else {
                val errorMsg = response.errorBody()?.string() ?: "Unknown Cloud Error"
                withContext(Dispatchers.Main) { Toast.makeText(context, "Sync Rejected: $errorMsg", Toast.LENGTH_LONG).show() }
                Log.e(tag, "Cloud sync rejected: ${response.code()} $errorMsg")
                false
            }
        } catch (e: Exception) {
            Log.e(tag, "Recovery failed with critical error: ${e.message}")
            withContext(Dispatchers.Main) { Toast.makeText(context, "Critical Recovery Error: ${e.message}", Toast.LENGTH_LONG).show() }
            false
        }
    }
}
