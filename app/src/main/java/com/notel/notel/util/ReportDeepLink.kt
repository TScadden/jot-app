package com.notel.notel.util

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Transient deep-link requests into the Progress Reports screen
 * (Phase 2, WS-H). The report-draft-ready notification taps MainActivity
 * with extras; MainActivity forwards them here; SettingsScreen observes
 * and switches to the Progress Reports menu. Singleton, in-memory only —
 * a request that arrives while the app is dead is delivered on next
 * launch via the same extras.
 */
@Singleton
class ReportDeepLink @Inject constructor() {
    private val _openProgressReports = MutableStateFlow<String?>(null)

    /**
     * Non-null while a navigation request is pending. The string is the
     * scheduled event id, or "" when no event is attached.
     */
    val openProgressReports = _openProgressReports.asStateFlow()

    fun request(eventId: String? = null) {
        _openProgressReports.value = eventId ?: ""
    }

    fun consume() {
        _openProgressReports.value = null
    }
}
