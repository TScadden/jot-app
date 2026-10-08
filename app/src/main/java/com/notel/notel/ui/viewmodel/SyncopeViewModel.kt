package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.repository.SyncopeRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class SyncopeViewModel @Inject constructor(
    private val repository: SyncopeRepository
) : ViewModel() {

    val allEvents = repository.allEvents
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _justLogged = MutableStateFlow(false)
    val justLogged: StateFlow<Boolean> = _justLogged.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun logEvent(
        type: String,
        prodromes: List<String>,
        postureAtOnset: String,
        location: String,
        recoveryMinutes: Int,
        notes: String = ""
    ) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                repository.logEvent(type, prodromes, postureAtOnset, location, recoveryMinutes, notes)
                _error.value = null
                _justLogged.value = true
            } catch (e: Exception) {
                _error.value = "Could not save the episode. Please try again."
            }
        }
    }

    fun consumeJustLogged() { _justLogged.value = false }
    fun clearError() { _error.value = null }
}
