package com.notel.notel.ui.viewmodel

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.dao.CoachMessageDao
import com.notel.notel.data.local.dao.CoachSessionDao
import com.notel.notel.data.local.entity.CoachMessageEntity
import com.notel.notel.data.local.entity.CoachSession
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.CoachMessageDto
import com.notel.notel.data.remote.JotApi
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.UUID
import javax.inject.Inject

enum class NoteStatus {
    NONE,
    PENDING,
    APPROVED,
    DENIED
}

data class CoachMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: String, // "user" or "coach"
    val content: String,
    val isLoading: Boolean = false,
    val proposedNoteText: String? = null,
    val noteStatus: NoteStatus = NoteStatus.NONE
)

fun parseCoachMessageContent(rawContent: String): Triple<String, String?, NoteStatus> {
    val proposeRegex = Regex("\\[PROPOSE_NOTE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val approveRegex = Regex("\\[APPROVED_NOTE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val denyRegex = Regex("\\[DENIED_NOTE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)

    return when {
        proposeRegex.containsMatchIn(rawContent) -> {
            val matchResult = proposeRegex.find(rawContent)!!
            val noteText = matchResult.groupValues[1].trim()
            val cleanContent = rawContent.replace(matchResult.value, "").trim()
            Triple(cleanContent, noteText, NoteStatus.PENDING)
        }
        approveRegex.containsMatchIn(rawContent) -> {
            val matchResult = approveRegex.find(rawContent)!!
            val noteText = matchResult.groupValues[1].trim()
            val cleanContent = rawContent.replace(matchResult.value, "").trim()
            Triple(cleanContent, noteText, NoteStatus.APPROVED)
        }
        denyRegex.containsMatchIn(rawContent) -> {
            val matchResult = denyRegex.find(rawContent)!!
            val noteText = matchResult.groupValues[1].trim()
            val cleanContent = rawContent.replace(matchResult.value, "").trim()
            Triple(cleanContent, noteText, NoteStatus.DENIED)
        }
        else -> {
            Triple(rawContent, null, NoteStatus.NONE)
        }
    }
}

@HiltViewModel
class CoachViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences,
    private val coachSessionDao: CoachSessionDao,
    private val coachMessageDao: CoachMessageDao,
    private val jotApi: JotApi,
    savedStateHandle: SavedStateHandle
) : ViewModel() {

    private val _currentSessionId = MutableStateFlow(savedStateHandle.get<String>("sessionId"))

    private val _loadingMessage = MutableStateFlow<CoachMessage?>(null)
    
    // Default greeting for new sessions
    private val welcomeMessage = CoachMessage(
        role = "coach",
        content = "Hi! I'm Jot Coach. I have context on your recent logs, body load history, and knowledge base. How can I help you today?"
    )

    @kotlinx.coroutines.ExperimentalCoroutinesApi
    val messages: StateFlow<List<CoachMessage>> = _currentSessionId.flatMapLatest { sessionId ->
        if (sessionId == null) {
            flowOf(listOf(welcomeMessage))
        } else {
            coachMessageDao.getMessagesForSession(sessionId).map { entities ->
                entities.map { entity ->
                    val (cleanContent, noteText, status) = parseCoachMessageContent(entity.content)
                    CoachMessage(
                        id = entity.id,
                        role = entity.role,
                        content = cleanContent,
                        proposedNoteText = noteText,
                        noteStatus = status
                    )
                }
            }
        }
    }.combine(_loadingMessage) { dbMessages, loadingMsg ->
        if (loadingMsg != null) {
            dbMessages + loadingMsg
        } else {
            dbMessages
        }
    }.stateIn(viewModelScope, SharingStarted.Lazily, listOf(welcomeMessage))

    fun approveProposedNote(messageId: String, noteText: String) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch
                
                // 1. Save the note to history
                logRepository.handleVoiceNote(noteText, useAI = true)
                
                // 2. Update the proposed message tag in SQLite to APPROVED_NOTE
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace("[PROPOSE_NOTE:", "[APPROVED_NOTE:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }
                
                // 3. Insert direct confirmation message
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Great! I've saved that note to your history."
                    )
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun denyProposedNote(messageId: String) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch
                
                // 1. Update the proposed message tag in SQLite to DENIED_NOTE
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace("[PROPOSE_NOTE:", "[DENIED_NOTE:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }
                
                // 2. Insert direct confirmation message
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Okay, I won't save that note."
                    )
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }    fun deleteCurrentSession(onDeleted: () -> Unit) {
        val sessionId = _currentSessionId.value ?: return
        viewModelScope.launch {
            try {
                // 1. Get current session
                val session = coachSessionDao.getSessionById(sessionId)
                if (session != null) {
                    // 2. Delete local session (ON DELETE CASCADE deletes local messages)
                    coachSessionDao.deleteSession(session)
                }
                
                // 3. Delete from backend server
                if (preferences.loggedIn.first()) {
                    jotApi.deleteCoachSession(sessionId)
                }
                
                // 4. Return to previous screen
                onDeleted()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun sendMessage(text: String) {
        if (text.isBlank()) return

        val userMsgId = UUID.randomUUID().toString()
        val userText = text.trim()

        val lastMsg = messages.value.lastOrNull { !it.isLoading }
        if (lastMsg != null && lastMsg.noteStatus == NoteStatus.PENDING && lastMsg.proposedNoteText != null) {
            val lowerText = userText.lowercase()
            if (lowerText == "approve" || lowerText == "yes" || lowerText == "save" || lowerText == "save it" || lowerText == "save that" || lowerText == "please save it" || lowerText == "please save that") {
                approveProposedNote(lastMsg.id, lastMsg.proposedNoteText)
                return
            } else if (lowerText == "deny" || lowerText == "no" || lowerText == "don't save" || lowerText == "don't save that" || lowerText == "cancel" || lowerText == "no don't save") {
                denyProposedNote(lastMsg.id)
                return
            }
        }

        viewModelScope.launch {
            try {
                // 1. Ensure Session exists
                var sessionId = _currentSessionId.value
                if (sessionId == null) {
                    val newSessionId = UUID.randomUUID().toString()
                    sessionId = newSessionId
                    
                    // Save session
                    val tempSession = CoachSession(id = newSessionId, title = "New Chat")
                    coachSessionDao.insertSession(tempSession)

                    // Save the initial greeting message to DB
                    coachMessageDao.insertMessage(
                        CoachMessageEntity(
                            sessionId = newSessionId,
                            role = "coach",
                            content = welcomeMessage.content
                        )
                    )

                    // Update StateFlow
                    _currentSessionId.value = newSessionId

                    // Ask AI for a title in background
                    launch {
                        val titleRes = logRepository.generateCoachTitle(userText)
                        val newTitle = titleRes.getOrNull() ?: "Chat"
                        coachSessionDao.updateSession(tempSession.copy(title = newTitle, updatedAt = System.currentTimeMillis(), isSynced = false))
                    }
                }

                // 2. Save user message to DB
                coachSessionDao.updateSession(coachSessionDao.getSessionById(sessionId)!!.copy(updatedAt = System.currentTimeMillis(), isSynced = false))
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        id = userMsgId,
                        sessionId = sessionId,
                        role = "user",
                        content = userText
                    )
                )

                // 3. Show loading indicator
                val loadingId = UUID.randomUUID().toString()
                _loadingMessage.value = CoachMessage(id = loadingId, role = "coach", content = "", isLoading = true)

                // 4. Fire API request (fetch up-to-date list directly from database to guarantee user message inclusion)
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val currentHistory = dbEntities.map {
                    CoachMessageDto(
                        id = it.id,
                        sessionId = sessionId,
                        role = it.role,
                        content = it.content,
                        timestamp = it.timestamp
                    )
                }
                
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
                        _loadingMessage.value = null
                        val aiMsgId = UUID.randomUUID().toString()
                        coachMessageDao.insertMessage(
                            CoachMessageEntity(
                                id = aiMsgId,
                                sessionId = sessionId,
                                role = "coach",
                                content = replyText
                            )
                        )
                    },
                    onFailure = { error ->
                        _loadingMessage.value = CoachMessage(id = loadingId, role = "coach", content = "Sorry, I had trouble connecting: ${error.message}", isLoading = false)
                    }
                )
            } catch (e: Exception) {
                _loadingMessage.value = CoachMessage(id = UUID.randomUUID().toString(), role = "coach", content = "An unexpected error occurred.", isLoading = false)
            }
        }
    }
}
