package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.CoachMessageDto
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

data class CoachMessage(
    val id: String = java.util.UUID.randomUUID().toString(),
    val role: String, // "user" or "coach"
    val content: String,
    val isLoading: Boolean = false
)

@HiltViewModel
class CoachViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences
) : ViewModel() {

    private val _messages = MutableStateFlow<List<CoachMessage>>(
        listOf(
            CoachMessage(
                role = "coach",
                content = "Hi! I'm Jot Coach. I have context on your recent logs, body load history, and knowledge base. How can I help you today?"
            )
        )
    )
    val messages: StateFlow<List<CoachMessage>> = _messages.asStateFlow()

    fun sendMessage(text: String) {
        if (text.isBlank()) return

        // 1. Add user message
        val userMsg = CoachMessage(role = "user", content = text.trim())
        
        // 2. Add loading placeholder for coach
        val loadingId = java.util.UUID.randomUUID().toString()
        val loadingMsg = CoachMessage(id = loadingId, role = "coach", content = "", isLoading = true)

        _messages.value = _messages.value + userMsg + loadingMsg

        // 3. Fire API request
        viewModelScope.launch {
            try {
                val currentHistory = _messages.value
                    .filter { !it.isLoading && it.id != loadingId }
                    .map { CoachMessageDto(role = it.role, content = it.content) }
                
                val userCtx = preferences.userContext.first()
                val kb = preferences.knowledgeBase.first()
                val recentEntries = logRepository.getRecentEntriesAll(10)

                val result = logRepository.sendCoachMessage(
                    messages = currentHistory,
                    userContext = userCtx.ifBlank { null },
                    knowledgeBase = kb.ifBlank { null },
                    recentEntries = recentEntries
                )

                result.fold(
                    onSuccess = { replyText ->
                        // Replace loading message with actual reply
                        _messages.value = _messages.value.map {
                            if (it.id == loadingId) it.copy(content = replyText, isLoading = false) else it
                        }
                    },
                    onFailure = { error ->
                        // Replace loading message with error
                        _messages.value = _messages.value.map {
                            if (it.id == loadingId) it.copy(content = "Sorry, I had trouble connecting: ${error.message}", isLoading = false) else it
                        }
                    }
                )
            } catch (e: Exception) {
                _messages.value = _messages.value.map {
                    if (it.id == loadingId) it.copy(content = "An unexpected error occurred.", isLoading = false) else it
                }
            }
        }
    }
}
