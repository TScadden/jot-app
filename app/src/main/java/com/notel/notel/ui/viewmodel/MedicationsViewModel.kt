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
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class MedicationsViewModel @Inject constructor(
    private val medicationDao: MedicationDao,
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences,
    private val geminiService: GeminiService
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

    fun addMedication(name: String, dose: String, frequency: String) {
        if (name.isBlank() || dose.isBlank()) return
        viewModelScope.launch {
            val med = Medication(
                name = name.trim(),
                dose = dose.trim(),
                frequency = frequency.trim().ifEmpty { "Once daily" }
            )
            medicationDao.insertMedication(med)
            _statusMessage.value = "Added ${med.name} (${med.dose})"
        }
    }

    fun archiveMedication(medication: Medication) {
        viewModelScope.launch {
            val todayStr = java.text.SimpleDateFormat("MMM d, yyyy", java.util.Locale.getDefault()).format(java.util.Date())
            val updated = medication.copy(isArchived = true, endedDate = todayStr)
            medicationDao.insertMedication(updated)
            _statusMessage.value = "Archived ${medication.name} (Ended $todayStr)"
        }
    }

    fun unarchiveMedication(medication: Medication) {
        viewModelScope.launch {
            val updated = medication.copy(isArchived = false, endedDate = null)
            medicationDao.insertMedication(updated)
            _statusMessage.value = "Re-activated ${medication.name}"
        }
    }

    fun deleteMedication(medication: Medication) {
        viewModelScope.launch {
            medicationDao.deleteMedication(medication)
            _statusMessage.value = "Permanently deleted ${medication.name}"
        }
    }

    fun loadMedicationsFromProfile() {
        viewModelScope.launch {
            _isExtractingFromProfile.value = true
            val profileContext = preferences.userContext.first()
            if (profileContext.isBlank()) {
                _statusMessage.value = "No user profile background found to extract meds from."
                _isExtractingFromProfile.value = false
                return@launch
            }

            val extracted = extractMedicationsFromText(profileContext)

            if (extracted.isEmpty()) {
                _statusMessage.value = "No clear medication names found in profile background."
            } else {
                for (med in extracted) {
                    medicationDao.insertMedication(med)
                }
                _statusMessage.value = "Successfully imported ${extracted.size} medication(s) from profile!"
            }
            _isExtractingFromProfile.value = false
        }
    }

    private fun extractMedicationsFromText(text: String): List<Medication> {
        val stopWords = setOf("and", "one", "two", "the", "for", "with", "take", "taking", "every", "some", "time", "day", "daily", "week", "weekly", "mg", "mcg", "000")
        val results = mutableListOf<Medication>()

        // Match patterns like "Semaglutide 0.5mg once weekly", "Cymbalta 60mg daily", "Metformin 500mg twice a day"
        val regex = Regex("(?i)\\b([a-zA-Z]{3,20})\\s+(\\d+(?:\\.\\d+)?\\s*(?:mg|mcg|iu|ml|g|tablets?|pills?))\\s*([^,.\\n\\r]*)")
        val matches = regex.findAll(text)

        for (match in matches) {
            val rawName = match.groupValues[1].lowercase().trim()
            val dose = match.groupValues[2].replace(" ", "").trim()
            var freq = match.groupValues[3].trim().ifEmpty { "Daily" }

            if (freq.length > 25) {
                freq = freq.take(25)
            }

            if (!stopWords.contains(rawName) && rawName.length >= 3 && !rawName.all { it.isDigit() }) {
                val formattedName = rawName.replaceFirstChar { it.uppercase() }
                if (results.none { it.name.equals(formattedName, ignoreCase = true) }) {
                    results.add(
                        Medication(
                            name = formattedName,
                            dose = dose,
                            frequency = freq.ifEmpty { "Daily" }
                        )
                    )
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
            source = "Medications Tab"
        )
        val entryId = logRepository.insertEntry(newEntry)

        // Check local cache for AI side-effect lookups to prevent credit waste
        val cacheKey = "${med.name.lowercase()}_${med.dose.lowercase()}"
        val cached = medicationDao.getSideEffectCache(cacheKey)
        
        if (cached == null) {
            // Trigger AI side effect lookup and cache it locally
            val dummyEntry = LogEntry(id = entryId, categoryId = 8, body = logText)
            val aiResult = geminiService.evaluateBodyImpacts(listOf(dummyEntry))
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
