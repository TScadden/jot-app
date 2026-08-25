package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

data class HistoryUiState(
    val entries: List<LogEntry> = emptyList(),
    val searchQuery: String = "",
    val selectedCategoryFilter: Int? = null  // null = all
)

@HiltViewModel
class HistoryViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository
) : ViewModel() {

    private val _searchQuery = MutableStateFlow("")
    private val _categoryFilter = MutableStateFlow<Int?>(null)

    val categories = categoryRepository.getAllCategories()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    @OptIn(ExperimentalCoroutinesApi::class)
    val entries: StateFlow<List<LogEntry>> = combine(_searchQuery, _categoryFilter) { q, cat ->
        Pair(q, cat)
    }.flatMapLatest { (query, categoryId) ->
        when {
            query.isNotBlank() -> logRepository.searchEntries(query)
            categoryId != null -> logRepository.getEntriesByCategory(categoryId)
            else -> logRepository.getAllEntries()
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val aiInsightsWithDetails: StateFlow<List<com.notel.notel.data.local.entity.AiInsightWithEntryAndCategory>> = 
        logRepository.getAllInsightsWithEntryAndCategory()
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val searchQuery: StateFlow<String> = _searchQuery
    val categoryFilter: StateFlow<Int?> = _categoryFilter

    fun setSearchQuery(q: String) = _searchQuery.update { q }
    fun setCategoryFilter(id: Int?) = _categoryFilter.update { id }

    fun deleteEntry(entry: LogEntry) {
        viewModelScope.launch { logRepository.deleteEntry(entry) }
    }
}
