package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import java.util.*
import javax.inject.Inject

data class TrendsState(
    val isLoading: Boolean = true,
    val totalLogs: Int = 0,
    val frequencyByHour: Map<Int, Int> = emptyMap(),
    val frequencyByCategory: Map<Int, Int> = emptyMap(),
    val topChips: List<Pair<String, Int>> = emptyList(),
    val categories: List<Category> = emptyList(),
    val selectedHour: Int? = null,
    val filteredLogs: List<LogEntry> = emptyList(),
    val dayOffset: Int = 0,
    val dateLabel: String = "",
    val selectedSymptom: String? = null,
    val logsForSymptom: List<LogEntry> = emptyList()
)

@HiltViewModel
class TrendsViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository
) : ViewModel() {

    private val _state = MutableStateFlow(TrendsState())
    val state = _state.asStateFlow()

    private var allEntries: List<LogEntry> = emptyList()
    private var currentFilteredEntries: List<LogEntry> = emptyList()
    private val dayOffsetFlow = MutableStateFlow(0)

    init {
        loadData()
    }

    private fun loadData() {
        viewModelScope.launch {
            combine(
                logRepository.getAllEntries(),
                categoryRepository.getAllCategories(),
                dayOffsetFlow
            ) { entries, cats, offset ->
                allEntries = entries

                val cal = Calendar.getInstance()
                cal.add(Calendar.DAY_OF_YEAR, offset)

                val format = java.text.SimpleDateFormat("MMM dd, yyyy", Locale.getDefault())
                val targetDateStr = format.format(cal.time)
                val dateLabel = when {
                    offset == 0 -> "Today"
                    offset == -1 -> "Yesterday"
                    else -> targetDateStr
                }

                cal.set(Calendar.HOUR_OF_DAY, 0)
                cal.set(Calendar.MINUTE, 0)
                cal.set(Calendar.SECOND, 0)
                cal.set(Calendar.MILLISECOND, 0)
                val startOfDay = cal.timeInMillis
                val endOfDay = startOfDay + 24 * 60 * 60 * 1000L - 1

                currentFilteredEntries = entries.filter { it.timestamp in startOfDay..endOfDay }

                val hourlyFreq = currentFilteredEntries.groupBy {
                    Calendar.getInstance().apply { timeInMillis = it.timestamp }.get(Calendar.HOUR_OF_DAY)
                }.mapValues { it.value.size }

                val catFreq = currentFilteredEntries.groupBy { it.categoryId }.mapValues { it.value.size }

                val chips = allEntries.flatMap {
                    try {
                        Json.decodeFromString<List<String>>(it.chips)
                    } catch (_: Exception) {
                        emptyList()
                    }
                }
                    .filter { it.isNotBlank() }
                    .groupBy { it }
                    .mapValues { it.value.size }
                    .toList()
                    .sortedByDescending { it.second }

                _state.value = _state.value.copy(
                    isLoading = false,
                    totalLogs = currentFilteredEntries.size,
                    frequencyByHour = hourlyFreq,
                    frequencyByCategory = catFreq,
                    topChips = chips,
                    categories = cats,
                    dayOffset = offset,
                    dateLabel = dateLabel
                )
                
                // Re-apply selected hour filter if it is currently selected
                _state.value.selectedHour?.let { selectHour(it) }

            }.collect()
        }
    }

    fun selectHour(hour: Int) {
        val filtered = currentFilteredEntries.filter { 
            Calendar.getInstance().apply { timeInMillis = it.timestamp }.get(Calendar.HOUR_OF_DAY) == hour
        }.sortedByDescending { it.timestamp }
        
        _state.value = _state.value.copy(
            selectedHour = hour,
            filteredLogs = filtered
        )
    }

    fun clearSelection() {
        _state.value = _state.value.copy(
            selectedHour = null,
            filteredLogs = emptyList(),
            selectedSymptom = null,
            logsForSymptom = emptyList()
        )
    }

    fun selectSymptom(symptom: String) {
        val filtered = allEntries.filter { log ->
            try {
                val decodedChips = Json.decodeFromString<List<String>>(log.chips)
                decodedChips.any { it.equals(symptom, ignoreCase = true) } || log.body.contains(symptom, ignoreCase = true)
            } catch(e: Exception) {
                log.body.contains(symptom, ignoreCase = true)
            }
        }.sortedByDescending { it.timestamp }
        
        _state.value = _state.value.copy(
            selectedSymptom = symptom,
            logsForSymptom = filtered,
            selectedHour = null // Clear hour filter if viewing symptom
        )
    }

    fun previousDay() {
        dayOffsetFlow.value -= 1
        clearSelection()
    }

    fun nextDay() {
        if (dayOffsetFlow.value < 0) {
            dayOffsetFlow.value += 1
            clearSelection()
        }
    }
}
