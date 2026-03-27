package com.notel.notel.data.sync

import android.util.Log
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SyncManager @Inject constructor(
    private val jotApi: JotApi,
    private val logEntryDao: LogEntryDao,
    private val categoryDao: CategoryDao,
    private val preferences: NotelPreferences
) {
    private val tag = "SyncManager"

    suspend fun syncAllData() = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext
            
            Log.d(tag, "Starting background sync...")
            
            // 1. Sync Categories
            val categories = categoryDao.getAllCategories().first()
            if (categories.isNotEmpty()) {
                val categoryDtos = categories.map {
                    CategoryDtoModel(it.id, it.name, it.icon, it.colorHex, it.isDefault, it.sortOrder)
                }
                jotApi.syncCategories(SyncCategoriesRequest(categoryDtos))
                Log.d(tag, "Synced ${categories.size} categories")
            }

            // 2. Sync Entries
            val entries = logEntryDao.getAllEntries().first()
            if (entries.isNotEmpty()) {
                val entryDtos = entries.map {
                    LogEntryDtoModel(it.id, it.categoryId, it.body, it.chips, it.manualText, it.timestamp)
                }
                jotApi.syncEntries(SyncEntriesRequest(entryDtos))
                Log.d(tag, "Synced ${entries.size} entries")
            }

            // 3. Sync Profile
            jotApi.syncProfile(
                SyncProfileRequest(
                    userContext = preferences.userContext.first(),
                    knowledgeBase = preferences.knowledgeBase.first(),
                    professionalUpdates = preferences.professionalUpdates.first(),
                    processedFiles = preferences.processedFiles.first(),
                    loggedDays = preferences.loggedDays.first(),
                    age = preferences.userAge.first(),
                    heightCm = preferences.userHeight.first(),
                    weightKg = preferences.userWeight.first(),
                    gender = preferences.userGender.first(),
                    onboardingComplete = preferences.onboardingComplete.first(),
                    autoAiSuggestions = preferences.autoAiSuggestions.first(),
                    eventCounters = preferences.eventCounters.first(),
                    counterHistory = preferences.counterHistory.first()
                )
            )
            Log.d(tag, "Synced user profile config")

            // 4. Extract Insights from past AI interactions if needed (Currently skipping for MVP)
            
            Log.d(tag, "Background sync push complete!")
        } catch (e: Exception) {
            Log.e(tag, "Background sync push failed: ${e.message}")
        }
    }

    suspend fun pullAllData() = withContext(Dispatchers.IO) {
        try {
            if (!preferences.loggedIn.first()) return@withContext
            Log.d(tag, "Starting background pull...")
            val response = jotApi.pullData()
            val body = response.body()
            
            if (response.isSuccessful && body != null) {
                body.profile?.let { profile ->
                    profile.userContext?.let { preferences.setUserContext(it) }
                    profile.knowledgeBase?.let { preferences.setKnowledgeBase(it) }
                    profile.professionalUpdates?.let { preferences.setProfessionalUpdates(it) }
                    profile.processedFiles?.let { preferences.setProcessedFiles(it) }
                    profile.loggedDays?.let { preferences.setLoggedDays(it) }
                    profile.age?.let { preferences.setUserAge(it) }
                    profile.heightCm?.let { preferences.setUserHeight(it) }
                    profile.weightKg?.let { preferences.setUserWeight(it) }
                    profile.gender?.let { preferences.setUserGender(it) }
                    profile.onboardingComplete?.let { preferences.setOnboardingComplete(it) }
                    profile.autoAiSuggestions?.let { preferences.setAutoAiSuggestions(it) }
                    profile.eventCounters?.let { preferences.setEventCounters(it) }
                    profile.counterHistory?.let { preferences.setCounterHistory(it) }
                }

                body.isUnlimited?.let { preferences.setIsUnlimited(it) }

                if (body.categories.isNotEmpty()) {
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
                    Log.d(tag, "Pulled ${catEntities.size} categories")
                }

                if (body.entries.isNotEmpty()) {
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
                    Log.d(tag, "Pulled ${entryEntities.size} entries")
                }
                
                Log.d(tag, "Background pull complete!")
            } else {
                Log.e(tag, "Pull failed: ${response.errorBody()?.string()}")
            }
        } catch (e: Exception) {
            Log.e(tag, "Background pull failed: ${e.message}")
        }
    }
}
