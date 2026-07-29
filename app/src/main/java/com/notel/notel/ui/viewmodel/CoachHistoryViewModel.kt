package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.dao.CoachSessionDao
import com.notel.notel.data.local.entity.CoachSession
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.TabsApi
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class CoachHistoryViewModel @Inject constructor(
    private val coachSessionDao: CoachSessionDao,
    private val preferences: NotelPreferences,
    private val tabsApi: TabsApi
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

    fun deleteSession(session: CoachSession) {
        viewModelScope.launch {
            try {
                // 1. Delete from local database (ON DELETE CASCADE handles messages)
                coachSessionDao.deleteSession(session)

                // 2. Delete from server
                if (preferences.loggedIn.first()) {
                    tabsApi.deleteCoachSession(session.id)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}
