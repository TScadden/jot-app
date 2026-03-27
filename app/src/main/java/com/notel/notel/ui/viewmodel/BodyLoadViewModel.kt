package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.remote.BodyLoadResponse
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class BodyLoadViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(BodyLoadState())
    val uiState = _uiState.asStateFlow()

    init {
        // Automatically load on init (when screen opens)
        refresh()
    }

    fun refresh() {
        if (_uiState.value.isLoading) return
        
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            val allCats = categoryRepository.getAllCategories().first()
            
            logRepository.getBodyLoad(allCats)
                .onSuccess { res ->
                    _uiState.value = _uiState.value.copy(
                        score = res.score,
                        factors = res.factors,
                        advice = res.advice,
                        isLoading = false
                    )
                }
                .onFailure { e ->
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        error = e.message ?: "Analysis failed"
                    )
                }
        }
    }
}

data class BodyLoadState(
    val score: Int = 0,
    val factors: List<String> = emptyList(),
    val advice: String? = null,
    val isLoading: Boolean = false,
    val error: String? = null
)
