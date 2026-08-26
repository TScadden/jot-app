package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.dao.MedicationDao
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.local.entity.MedicationSideEffectCache
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.GeminiService
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.data.sync.SyncManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import javax.inject.Inject

@HiltViewModel
class MedicationsViewModel @Inject constructor(
    private val medicationDao: MedicationDao,
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences,
    private val geminiService: GeminiService,
    private val syncManager: SyncManager
) : ViewModel() {

    private val allMedsFlow = medicationDao.getAllMedications()

    val activeMedications: StateFlow<List<Medication>> = allMedsFlow
        .map { list -> list.filter { !it.isArchived } }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5000),
            initialValue = emptyList()
        )

    val archivedMedications: StateFlow<List<Medication>> = allMedsFlow
        .map { list -> list.filter { it.isArchived } }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5000),
            initialValue = emptyList()
        )

    private val _isExtractingFromProfile = MutableStateFlow(false)
    val isExtractingFromProfile: StateFlow<Boolean> = _isExtractingFromProfile.asStateFlow()

    private val _statusMessage = MutableStateFlow<String?>(null)
    val statusMessage: StateFlow<String?> = _statusMessage.asStateFlow()

    fun clearStatusMessage() {
        _statusMessage.value = null
    }

    fun addMedication(name: String, dose: String, frequency: String, startedDate: String) {
        if (name.isBlank() || dose.isBlank()) return
        viewModelScope.launch {
            val med = Medication(
                id = 0L,
                uuid = java.util.UUID.randomUUID().toString(),
                name = name.trim(),
                dose = dose.trim(),
                frequency = frequency.trim().ifEmpty { "Once daily" },
                startedDate = startedDate.trim().ifEmpty { null },
                updatedAt = System.currentTimeMillis()
            )
            val newId = medicationDao.insertMedication(med)
            _statusMessage.value = "Added ${med.name} (${med.dose})"
            syncMedicationsToPreferencesAndCloud()
        }
    }

    fun updateMedication(medication: Medication, name: String, dose: String, frequency: String, startedDate: String = medication.startedDate ?: "", endedDate: String? = medication.endedDate) {
        if (name.isBlank() || dose.isBlank()) return
        viewModelScope.launch {
            val updated = medication.copy(
                name = name.trim(),
                dose = dose.trim(),
                frequency = frequency.trim().ifEmpty { "Once daily" },
                startedDate = startedDate.trim().ifEmpty { null },
                endedDate = endedDate?.trim()?.ifEmpty { null },
                updatedAt = System.currentTimeMillis()
            )
            medicationDao.insertMedication(updated)
            // Clear side effect cache for this med so AI generates fresh evaluation
            medicationDao.clearAllSideEffectCache()
            _statusMessage.value = "Updated ${updated.name}"
            syncMedicationsToPreferencesAndCloud()
        }
    }

    fun archiveMedication(medication: Medication) {
        viewModelScope.launch {
            val todayStr = java.text.SimpleDateFormat("MMM d, yyyy", java.util.Locale.getDefault()).format(java.util.Date())
            val updated = medication.copy(isArchived = true, endedDate = todayStr, updatedAt = System.currentTimeMillis())
            medicationDao.insertMedication(updated)
            _statusMessage.value = "Archived ${medication.name} (Ended $todayStr)"
            syncMedicationsToPreferencesAndCloud()
        }
    }

    fun unarchiveMedication(medication: Medication) {
        viewModelScope.launch {
            val updated = medication.copy(isArchived = false, endedDate = null, updatedAt = System.currentTimeMillis())
            medicationDao.insertMedication(updated)
            _statusMessage.value = "Re-activated ${medication.name}"
            syncMedicationsToPreferencesAndCloud()
        }
    }

    fun deleteMedication(medication: Medication) {
        viewModelScope.launch {
            // Soft delete with tombstone to prevent resurrection during sync
            val deleted = medication.copy(isDeleted = true, updatedAt = System.currentTimeMillis())
            medicationDao.insertMedication(deleted)
            _statusMessage.value = "Permanently deleted ${medication.name}"
            syncMedicationsToPreferencesAndCloud()
        }
    }

    private suspend fun syncMedicationsToPreferencesAndCloud() {
        try {
            val allMeds = medicationDao.getAllMedications().first().filter { !it.isDeleted }
            val mappedList = allMeds.map { med ->
                com.notel.notel.ui.viewmodel.Medication(
                    id = if (med.uuid.isNotBlank()) med.uuid else med.id.toString(),
                    name = med.name,
                    startDate = med.startedDate ?: "",
                    endDate = if (!med.isArchived) "Present" else (med.endedDate ?: ""),
                    isPresent = !med.isArchived,
                    dose = med.dose,
                    frequency = med.frequency,
                    updatedAt = med.updatedAt,
                    isDeleted = med.isDeleted
                )
            }
            preferences.setMedications(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(com.notel.notel.ui.viewmodel.Medication.serializer()), mappedList))
            
            syncManager.log("MEDS_SYNC: Saved ${mappedList.size} medication(s) locally. Pushing to cloud...")
            val success = syncManager.pushProfileData()
            if (success) {
                syncManager.log("MEDS_SYNC_SUCCESS: Successfully synchronized medication list to cloud ✓")
            } else {
                syncManager.log("MEDS_SYNC_WARN: Could not push medication updates to cloud server.")
            }
        } catch (e: Exception) {
            syncManager.log("MEDS_SYNC_ERROR: Failed to update preferences/cloud: ${e.message}")
        }
    }

    fun loadMedicationsFromProfile() {
        viewModelScope.launch {
            _isExtractingFromProfile.value = true
            val profileMedsJson = preferences.medications.first()
            val existingMeds = medicationDao.getAllMedications().first()
            val existingNames = existingMeds.map { it.name.trim().lowercase() }.toSet()
            
            if (profileMedsJson.isBlank() || profileMedsJson == "[]") {
                // Fallback to checking userContext background string if no profile medications exist
                val profileContext = preferences.userContext.first()
                if (profileContext.isBlank()) {
                    _statusMessage.value = "No medications found in User Profile settings."
                    _isExtractingFromProfile.value = false
                    return@launch
                }

                val extracted = extractMedicationsFromText(profileContext)
                val newItems = extracted.filter { !existingNames.contains(it.name.trim().lowercase()) }
                if (newItems.isEmpty()) {
                    _statusMessage.value = "All profile medications are already added."
                } else {
                    for (med in newItems) {
                        medicationDao.insertMedication(med)
                    }
                    _statusMessage.value = "Imported ${newItems.size} new medication(s) from profile!"
                }
                _isExtractingFromProfile.value = false
                return@launch
            }

            try {
                val jsonArray = org.json.JSONArray(profileMedsJson)
                var count = 0
                for (i in 0 until jsonArray.length()) {
                    val obj = jsonArray.getJSONObject(i)
                    val name = obj.optString("name", "").trim()
                    val isPresent = obj.optBoolean("isPresent", true)
                    
                    if (name.isNotBlank() && !existingNames.contains(name.lowercase())) {
                        val med = Medication(
                            name = name.replaceFirstChar { it.uppercase() },
                            dose = "As prescribed",
                            frequency = "Daily",
                            isArchived = !isPresent,
                            endedDate = if (!isPresent && obj.has("endDate")) obj.optString("endDate", "") else null
                        )
                        medicationDao.insertMedication(med)
                        count++
                    }
                }
                if (count > 0) {
                    _statusMessage.value = "Loaded $count new medication(s) from User Profile!"
                } else {
                    _statusMessage.value = "All profile medications are already added!"
                }
            } catch (e: Exception) {
                _statusMessage.value = "Failed to parse medications from User Profile."
            }
            _isExtractingFromProfile.value = false
        }
    }

    private fun extractMedicationsFromText(text: String): List<Medication> {
        val stopWords = setOf(
            "and", "one", "two", "the", "for", "with", "take", "taking", "every", "some",
            "time", "day", "daily", "week", "weekly", "mg", "mcg", "000", "profile", "info",
            "gender", "age", "height", "weight", "lbs", "user", "background", "goals", "training"
        )
        val results = mutableListOf<Medication>()

        // Split text by line breaks, semicolons, or commas
        val items = text.split("\n", ";", ",")

        for (item in items) {
            val cleanItem = item.trim()
            if (cleanItem.length < 3) continue

            // 1. Check for standard "Name Dose Frequency" pattern (e.g., "Semaglutide 0.5mg weekly")
            val regex = Regex("(?i)\\b([a-zA-Z]{3,25})\\b(?:\\s+(\\d+(?:\\.\\d+)?\\s*(?:mg|mcg|iu|ml|g|tablets?|pills?|units?)))?(?:\\s+([^,.\\n\\r]*))?")
            val match = regex.find(cleanItem)

            if (match != null) {
                val rawName = match.groupValues[1].lowercase().trim()
                val rawDose = match.groupValues[2].ifEmpty { 
                    // Fallback to find any dosage number in the line
                    Regex("(?i)\\b(\\d+(?:\\.\\d+)?\\s*(?:mg|mcg|iu|ml|g|tablets?|pills?|units?))\\b").find(cleanItem)?.value ?: "As prescribed"
                }.replace(" ", "")

                var rawFreq = match.groupValues[3].trim().ifEmpty { "Daily" }
                if (rawFreq.length > 25) rawFreq = rawFreq.take(25)

                if (!stopWords.contains(rawName) && rawName.length >= 3 && !rawName.all { it.isDigit() }) {
                    val formattedName = rawName.replaceFirstChar { it.uppercase() }
                    if (results.none { it.name.equals(formattedName, ignoreCase = true) }) {
                        results.add(
                            Medication(
                                name = formattedName,
                                dose = rawDose,
                                frequency = rawFreq
                            )
                        )
                    }
                }
            }
        }

        return results
    }

    fun takeSingleMedication(med: Medication) {
        viewModelScope.launch {
            logMedicationDose(med)
            _statusMessage.value = "Logged 1 dose of ${med.name} (${med.dose})"
        }
    }

    fun takeAllMedications() {
        viewModelScope.launch {
            val list = activeMedications.value
            if (list.isEmpty()) {
                _statusMessage.value = "No active medications available to take."
                return@launch
            }

            for (med in list) {
                logMedicationDose(med)
            }
            _statusMessage.value = "Logged 1 dose for all ${list.size} medication(s)!"
        }
    }

    private suspend fun logMedicationDose(med: Medication) {
        // Log exactly 1 dose (not full day's worth)
        val logText = "Took Medication: ${med.name} ${med.dose} (1 dose - ${med.frequency})"
        
        // 8 is the Medication category ID
        val newEntry = LogEntry(
            categoryId = 8,
            body = logText,
            manualText = "Logged from Medications tab",
            source = "Medications Tab",
            chips = "[\"Medication Tab\"]"
        )
        val entryId = logRepository.insertEntry(newEntry)

        // Check local cache for AI side-effect lookups to prevent credit waste
        val cacheKey = "${med.name.lowercase()}_${med.dose.lowercase()}"
        val cached = medicationDao.getSideEffectCache(cacheKey)
        
        if (cached == null) {
            // Trigger AI side effect lookup with full profile context and cache it locally
            val userContextStr = preferences.userContext.first()
            val profileMedsStr = preferences.medications.first()
            val combinedContext = "User Profile Context: $userContextStr\nProfile Medications: $profileMedsStr"

            val dummyEntry = LogEntry(id = entryId, categoryId = 8, body = logText)
            val aiResult = geminiService.evaluateBodyImpacts(listOf(dummyEntry), userContext = combinedContext)
            aiResult.getOrNull()?.let { items ->
                val json = kotlinx.serialization.json.Json.encodeToString(
                    com.notel.notel.data.remote.AiBodyImpactResponse.serializer(),
                    com.notel.notel.data.remote.AiBodyImpactResponse(items)
                )
                medicationDao.insertSideEffectCache(
                    MedicationSideEffectCache(medKey = cacheKey, sideEffectsJson = json)
                )
            }
        }
    }
}
