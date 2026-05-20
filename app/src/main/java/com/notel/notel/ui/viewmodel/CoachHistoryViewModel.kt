package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.dao.CoachSessionDao
import com.notel.notel.data.local.entity.CoachSession
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class CoachHistoryViewModel @Inject constructor(
    private val coachSessionDao: CoachSessionDao
) : ViewModel() {

    private val _sessions = MutableStateFlow<List<CoachSession>>(emptyList())
    val sessions: StateFlow<List<CoachSession>> = _sessions.asStateFlow()

    init {
        viewModelScope.launch {
            coachSessionDao.getAllSessions().collectLatest {
                _sessions.value = it
            }
        }
    }
}
