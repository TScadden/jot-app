package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.util.BodyImpactEngine
import com.notel.notel.util.EvaluatedBodyImpact
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject

@HiltViewModel
class BodyInfoViewModel @Inject constructor(
    private val logRepository: LogRepository
) : ViewModel() {

    val activeImpacts: StateFlow<List<EvaluatedBodyImpact>> = logRepository.getAllEntries()
        .map { entries ->
            BodyImpactEngine.evaluateLogs(entries)
        }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5000),
            initialValue = emptyList()
        )
}
