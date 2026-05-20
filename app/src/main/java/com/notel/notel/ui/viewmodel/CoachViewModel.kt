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

enum class FileStatus {
    NONE,
    PENDING,
    APPROVED,
    DENIED
}

data class PendingUploadFile(
    val name: String,
    val mimeType: String,
    val base64Data: String,
    val extractedText: String
)

data class CoachMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: String, // "user" or "coach"
    val content: String,
    val isLoading: Boolean = false,
    val proposedNoteText: String? = null,
    val noteStatus: NoteStatus = NoteStatus.NONE,
    val proposedFileName: String? = null,
    val fileStatus: FileStatus = FileStatus.NONE
)

data class CoachMessageParsed(
    val cleanContent: String,
    val proposedNoteText: String?,
    val noteStatus: NoteStatus,
    val proposedFileName: String?,
    val fileStatus: FileStatus
)

fun parseCoachMessageContent(rawContent: String): CoachMessageParsed {
    val proposeRegex = Regex("\\[PROPOSE_NOTE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val approveRegex = Regex("\\[APPROVED_NOTE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val denyRegex = Regex("\\[DENIED_NOTE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)

    val proposeFileRegex = Regex("\\[PROPOSE_FILE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val approveFileRegex = Regex("\\[APPROVED_FILE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val denyFileRegex = Regex("\\[DENIED_FILE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)

    var cleanContent = rawContent
    var proposedNoteText: String? = null
    var noteStatus = NoteStatus.NONE
    var proposedFileName: String? = null
    var fileStatus = FileStatus.NONE

    if (proposeRegex.containsMatchIn(cleanContent)) {
        val matchResult = proposeRegex.find(cleanContent)!!
        proposedNoteText = matchResult.groupValues[1].trim()
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        noteStatus = NoteStatus.PENDING
    } else if (approveRegex.containsMatchIn(cleanContent)) {
        val matchResult = approveRegex.find(cleanContent)!!
        proposedNoteText = matchResult.groupValues[1].trim()
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        noteStatus = NoteStatus.APPROVED
    } else if (denyRegex.containsMatchIn(cleanContent)) {
        val matchResult = denyRegex.find(cleanContent)!!
        proposedNoteText = matchResult.groupValues[1].trim()
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        noteStatus = NoteStatus.DENIED
    }

    if (proposeFileRegex.containsMatchIn(cleanContent)) {
        val matchResult = proposeFileRegex.find(cleanContent)!!
        proposedFileName = matchResult.groupValues[1].trim()
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        fileStatus = FileStatus.PENDING
    } else if (approveFileRegex.containsMatchIn(cleanContent)) {
        val matchResult = approveFileRegex.find(cleanContent)!!
        proposedFileName = matchResult.groupValues[1].trim()
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        fileStatus = FileStatus.APPROVED
    } else if (denyFileRegex.containsMatchIn(cleanContent)) {
        val matchResult = denyFileRegex.find(cleanContent)!!
        proposedFileName = matchResult.groupValues[1].trim()
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        fileStatus = FileStatus.DENIED
    }

    return CoachMessageParsed(cleanContent, proposedNoteText, noteStatus, proposedFileName, fileStatus)
}


@HiltViewModel
class CoachViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val preferences: NotelPreferences,
    private val coachSessionDao: CoachSessionDao,
    private val coachMessageDao: CoachMessageDao,
    private val jotApi: JotApi,
    private val geminiService: com.notel.notel.data.remote.GeminiService,
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
                    val parsed = parseCoachMessageContent(entity.content)
                    CoachMessage(
                        id = entity.id,
                        role = entity.role,
                        content = parsed.cleanContent,
                        proposedNoteText = parsed.proposedNoteText,
                        noteStatus = parsed.noteStatus,
                        proposedFileName = parsed.proposedFileName,
                        fileStatus = parsed.fileStatus
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
                logRepository.handleCoachNote(noteText)
                
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

    private val pendingFiles = java.util.concurrent.ConcurrentHashMap<String, PendingUploadFile>()

    private fun getFileName(uri: android.net.Uri, contentResolver: android.content.ContentResolver): String? {
        var name: String? = null
        val cursor = contentResolver.query(uri, null, null, null, null)
        cursor?.use {
            if (it.moveToFirst()) {
                val index = it.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (index != -1) name = it.getString(index)
            }
        }
        return name
    }

    fun uploadFile(uri: android.net.Uri, contentResolver: android.content.ContentResolver) {
        viewModelScope.launch {
            try {
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
                }

                // 1. Read file metadata and bytes
                val fileName = getFileName(uri, contentResolver) ?: "unknown_file"
                val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
                val fileBytes = contentResolver.openInputStream(uri)?.use { stream ->
                    stream.readBytes()
                } ?: throw Exception("Could not read file content")
                val base64 = android.util.Base64.encodeToString(fileBytes, android.util.Base64.NO_WRAP)

                // 2. Show loading message in chat
                val loadingId = UUID.randomUUID().toString()
                _loadingMessage.value = CoachMessage(id = loadingId, role = "coach", content = "Extracting text from $fileName...", isLoading = true)

                // 3. Call text extraction via Gemini API
                val extractionResult = geminiService.processDocumentFile(mimeType, base64)
                
                _loadingMessage.value = null

                extractionResult.fold(
                    onSuccess = { extractedText ->
                        // Cache file details for saving upon approval
                        pendingFiles[fileName] = PendingUploadFile(
                            name = fileName,
                            mimeType = mimeType,
                            base64Data = base64,
                            extractedText = extractedText
                        )

                        // Save the user message in DB with formatted file tag
                        val userMsgId = UUID.randomUUID().toString()
                        val userMsgContent = "📄 Uploaded file: $fileName\n\n$extractedText"
                        coachSessionDao.updateSession(coachSessionDao.getSessionById(sessionId!!)!!.copy(updatedAt = System.currentTimeMillis(), isSynced = false))
                        coachMessageDao.insertMessage(
                            CoachMessageEntity(
                                id = userMsgId,
                                sessionId = sessionId,
                                role = "user",
                                content = userMsgContent
                            )
                        )

                        // Show loader for the AI coach's reply
                        val replyLoadingId = UUID.randomUUID().toString()
                        _loadingMessage.value = CoachMessage(id = replyLoadingId, role = "coach", content = "", isLoading = true)

                        // 4. Retrieve complete chat history and request reply from AI Coach
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

                        val coachReplyResult = logRepository.sendCoachMessage(
                            messages = currentHistory,
                            userContext = userCtx.ifBlank { null },
                            knowledgeBase = kb.ifBlank { null },
                            recentEntries = recentEntries
                        )

                        coachReplyResult.fold(
                            onSuccess = { replyText ->
                                _loadingMessage.value = null
                                coachMessageDao.insertMessage(
                                    CoachMessageEntity(
                                        sessionId = sessionId,
                                        role = "coach",
                                        content = replyText
                                    )
                                )
                            },
                            onFailure = { error ->
                                _loadingMessage.value = CoachMessage(id = replyLoadingId, role = "coach", content = "Sorry, I had trouble connecting: ${error.message}", isLoading = false)
                            }
                        )
                    },
                    onFailure = { error ->
                        _loadingMessage.value = CoachMessage(id = loadingId, role = "coach", content = "Extraction failed: ${error.message}", isLoading = false)
                    }
                )

            } catch (e: Exception) {
                _loadingMessage.value = CoachMessage(id = UUID.randomUUID().toString(), role = "coach", content = "An error occurred while uploading: ${e.message}", isLoading = false)
            }
        }
    }

    fun approveProposedFile(messageId: String, fileName: String) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch
                
                // 1. Retrieve the file from our pending cache, or fallback to reconstructing it
                val cached = pendingFiles[fileName]
                val mimeType = cached?.mimeType ?: "text/plain"
                val base64 = cached?.base64Data ?: run {
                    // Fallback: look up the user message containing the file content in history
                    val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                    val uploadMsg = dbEntities.find { it.role == "user" && it.content.startsWith("📄 Uploaded file: $fileName") }
                    val extractedText = uploadMsg?.content?.substringAfter("\n\n") ?: ""
                    android.util.Base64.encodeToString(extractedText.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
                }
                val extractedText = cached?.extractedText ?: run {
                    val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                    val uploadMsg = dbEntities.find { it.role == "user" && it.content.startsWith("📄 Uploaded file: $fileName") }
                    uploadMsg?.content?.substringAfter("\n\n") ?: ""
                }

                // 2. Ingest the pre-extracted document (saving it and triggering sync)
                logRepository.ingestPreExtractedDocumentFile(fileName, mimeType, base64, extractedText)

                // 3. Update the proposed message tag in SQLite to APPROVED_FILE
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace("[PROPOSE_FILE:", "[APPROVED_FILE:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }

                // 4. Insert direct confirmation message
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Great! I've saved \"$fileName\" to your Jot database. You can view it anytime in the Knowledge Extraction settings."
                    )
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun denyProposedFile(messageId: String) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch
                
                // 1. Update the proposed message tag in SQLite to DENIED_FILE
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace("[PROPOSE_FILE:", "[DENIED_FILE:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }
                
                // 2. Insert direct confirmation message
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Okay, I won't save that file to the database."
                    )
                )
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
        if (lastMsg != null) {
            if (lastMsg.noteStatus == NoteStatus.PENDING && lastMsg.proposedNoteText != null) {
                val lowerText = userText.lowercase()
                if (lowerText == "approve" || lowerText == "yes" || lowerText == "save" || lowerText == "save it" || lowerText == "save that" || lowerText == "please save it" || lowerText == "please save that") {
                    approveProposedNote(lastMsg.id, lastMsg.proposedNoteText)
                    return
                } else if (lowerText == "deny" || lowerText == "no" || lowerText == "don't save" || lowerText == "don't save that" || lowerText == "cancel" || lowerText == "no don't save") {
                    denyProposedNote(lastMsg.id)
                    return
                }
            } else if (lastMsg.fileStatus == FileStatus.PENDING && lastMsg.proposedFileName != null) {
                val lowerText = userText.lowercase()
                if (lowerText == "approve" || lowerText == "yes" || lowerText == "save" || lowerText == "save it" || lowerText == "save that" || lowerText == "please save it" || lowerText == "please save that") {
                    approveProposedFile(lastMsg.id, lastMsg.proposedFileName)
                    return
                } else if (lowerText == "deny" || lowerText == "no" || lowerText == "don't save" || lowerText == "don't save that" || lowerText == "cancel" || lowerText == "no don't save") {
                    denyProposedFile(lastMsg.id)
                    return
                }
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
