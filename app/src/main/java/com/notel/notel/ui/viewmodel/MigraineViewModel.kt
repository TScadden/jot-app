package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.MigraineAttack
import com.notel.notel.data.repository.MigraineRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

sealed class MigraineUiState {
    object Loading : MigraineUiState()
    data class Idle(val recentAttacks: List<MigraineAttack> = emptyList()) : MigraineUiState()
    data class Active(val attack: MigraineAttack) : MigraineUiState()
}

@HiltViewModel
class MigraineViewModel @Inject constructor(
    private val repository: MigraineRepository
) : ViewModel() {

    val allAttacks = repository.allAttacks
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _state = MutableStateFlow<MigraineUiState>(MigraineUiState.Loading)
    val state: StateFlow<MigraineUiState> = _state.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()
    fun clearError() { _error.value = null }

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val active = repository.getActiveAttack()
                if (active != null) {
                    _state.value = MigraineUiState.Active(active)
                } else {
                    _state.value = MigraineUiState.Idle(repository.getRecentAttacks(30))
                }
            } catch (e: Exception) {
                _state.value = MigraineUiState.Idle(emptyList())
            }
        }
    }

    fun startAttack() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val attack = repository.startAttack()
                _error.value = null
                _state.value = MigraineUiState.Active(attack)
            } catch (e: Exception) {
                _error.value = "Could not start the attack log. Please try again."
            }
        }
    }

    fun updateAttack(auraPhase: String? = null, medsTaken: String? = null, painPeak: Int? = null) {
        viewModelScope.launch(Dispatchers.IO) {
            repository.updateActiveAttack(auraPhase, medsTaken, painPeak)
            repository.getActiveAttack()?.let { _state.value = MigraineUiState.Active(it) }
        }
    }

    fun endAttack(reliefRating: Int, finalPainPeak: Int? = null) {
        viewModelScope.launch(Dispatchers.IO) {
            repository.endAttack(reliefRating, finalPainPeak)
            _state.value = MigraineUiState.Idle(repository.getRecentAttacks(30))
        }
    }
}
