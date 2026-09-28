package com.notel.notel.ui.viewmodel

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.repository.ConditionRepository
import com.notel.notel.data.research.ResearchEntry
import com.notel.notel.data.research.ResearchEntryLoader
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class ResearchViewModel @Inject constructor(
    private val application: Application,
    private val conditionRepository: ConditionRepository
) : ViewModel() {

    /** The user's own saved conditions (from profile / onboarding). */
    val userConditions: StateFlow<List<String>> = conditionRepository.conditions
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _entries = MutableStateFlow<List<ResearchEntry>>(emptyList())
    val entries: StateFlow<List<ResearchEntry>> = _entries.asStateFlow()

    init {
        viewModelScope.launch(Dispatchers.IO) {
            _entries.value = ResearchEntryLoader.load(application.applicationContext)
        }
    }
}
