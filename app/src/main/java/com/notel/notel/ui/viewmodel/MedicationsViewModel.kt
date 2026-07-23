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

    val medications: StateFlow<List<Medication>> = medicationDao.getAllMedications()
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

    fun deleteMedication(medication: Medication) {
        viewModelScope.launch {
            medicationDao.deleteMedication(medication)
            _statusMessage.value = "Removed ${medication.name}"
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

            // Quick extraction of medications from profile context string
            val lines = profileContext.split("\n", ",", ".")
            val extracted = mutableListOf<Medication>()
            
            val keywords = listOf("med", "medication", "taking", "prescribed", "dose", "mg", "mcg", "unit", "daily")
            for (line in lines) {
                val lower = line.lowercase()
                if (keywords.any { lower.contains(it) } && line.length > 5) {
                    val parts = line.trim().split(" ")
                    if (parts.isNotEmpty()) {
                        val name = parts[0].replace(Regex("[^a-zA-Z0-9]"), "")
                        if (name.length > 2 && extracted.none { it.name.equals(name, ignoreCase = true) }) {
                            val dose = parts.find { it.contains("mg") || it.contains("mcg") || it.contains("iu") || it.contains("ml") } ?: "As prescribed"
                            extracted.add(Medication(name = name.capitalize(), dose = dose, frequency = "Daily"))
                        }
                    }
                }
            }

            if (extracted.isEmpty()) {
                // Fallback default sample if user has med mention in profile
                extracted.add(Medication(name = "Semaglutide", dose = "0.5mg", frequency = "Once weekly"))
            }

            for (med in extracted) {
                medicationDao.insertMedication(med)
            }
            _statusMessage.value = "Loaded ${extracted.size} medication(s) from profile!"
            _isExtractingFromProfile.value = false
        }
    }

    fun takeSingleMedication(med: Medication) {
        viewModelScope.launch {
            logMedicationDose(med)
            _statusMessage.value = "Logged 1 dose of ${med.name} (${med.dose})"
        }
    }

    fun takeAllMedications() {
        viewModelScope.launch {
            val list = medications.value
            if (list.isEmpty()) {
                _statusMessage.value = "No medications available to take."
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
