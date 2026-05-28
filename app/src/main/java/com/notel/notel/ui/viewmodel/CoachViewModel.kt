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
import com.notel.notel.data.repository.ReminderRepository
import com.notel.notel.data.repository.UserListRepository
import com.notel.notel.data.local.entity.Reminder
import dagger.hilt.android.lifecycle.HiltViewModel
import java.util.UUID
import javax.inject.Inject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

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

enum class ListStatus {
    NONE,
    PENDING,
    APPROVED,
    DENIED
}

enum class ReminderStatus {
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
    val fileStatus: FileStatus = FileStatus.NONE,
    val proposedListName: String? = null,
    val proposedListItems: List<String> = emptyList(),
    val listStatus: ListStatus = ListStatus.NONE,
    val proposedReminderTitle: String? = null,
    val proposedReminderTime: String? = null, // "HH:MM"
    val reminderStatus: ReminderStatus = ReminderStatus.NONE
)

data class CoachMessageParsed(
    val cleanContent: String,
    val proposedNoteText: String?,
    val noteStatus: NoteStatus,
    val proposedFileName: String?,
    val fileStatus: FileStatus,
    val proposedListName: String?,
    val proposedListItems: List<String>,
    val listStatus: ListStatus,
    val proposedReminderTitle: String?,
    val proposedReminderTime: String?,
    val reminderStatus: ReminderStatus
)

fun parseCoachMessageContent(rawContent: String): CoachMessageParsed {
    val proposeRegex = Regex("\\[PROPOSE_NOTE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val approveRegex = Regex("\\[APPROVED_NOTE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val denyRegex = Regex("\\[DENIED_NOTE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)

    val proposeFileRegex = Regex("\\[PROPOSE_FILE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val approveFileRegex = Regex("\\[APPROVED_FILE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val denyFileRegex = Regex("\\[DENIED_FILE:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)

    val proposeListRegex = Regex("\\[PROPOSE_LIST:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val approveListRegex = Regex("\\[APPROVED_LIST:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val denyListRegex = Regex("\\[DENIED_LIST:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)

    val proposeReminderRegex = Regex("\\[PROPOSE_REMINDER:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val approveReminderRegex = Regex("\\[APPROVED_REMINDER:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)
    val denyReminderRegex = Regex("\\[DENIED_REMINDER:\\s*([^\\]]+)\\]", RegexOption.DOT_MATCHES_ALL)

    var cleanContent = rawContent
    var proposedNoteText: String? = null
    var noteStatus = NoteStatus.NONE
    var proposedFileName: String? = null
    var fileStatus = FileStatus.NONE
    var proposedListName: String? = null
    var proposedListItems: List<String> = emptyList()
    var listStatus = ListStatus.NONE
    var proposedReminderTitle: String? = null
    var proposedReminderTime: String? = null
    var reminderStatus = ReminderStatus.NONE

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

    fun parseListString(rawListString: String) {
        val parts = rawListString.split("|")
        proposedListName = parts.firstOrNull()?.trim()
        if (parts.size > 1) {
            proposedListItems = parts.subList(1, parts.size).map { it.trim() }.filter { it.isNotBlank() }
        }
    }

    if (proposeListRegex.containsMatchIn(cleanContent)) {
        val matchResult = proposeListRegex.find(cleanContent)!!
        parseListString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        listStatus = ListStatus.PENDING
    } else if (approveListRegex.containsMatchIn(cleanContent)) {
        val matchResult = approveListRegex.find(cleanContent)!!
        parseListString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        listStatus = ListStatus.APPROVED
    } else if (denyListRegex.containsMatchIn(cleanContent)) {
        val matchResult = denyListRegex.find(cleanContent)!!
        parseListString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        listStatus = ListStatus.DENIED
    }

    fun parseReminderString(raw: String) {
        val parts = raw.split("|")
        proposedReminderTitle = parts.getOrNull(0)?.trim()
        proposedReminderTime = parts.getOrNull(1)?.trim()
    }

    if (proposeReminderRegex.containsMatchIn(cleanContent)) {
        val matchResult = proposeReminderRegex.find(cleanContent)!!
        parseReminderString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        reminderStatus = ReminderStatus.PENDING
    } else if (approveReminderRegex.containsMatchIn(cleanContent)) {
        val matchResult = approveReminderRegex.find(cleanContent)!!
        parseReminderString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        reminderStatus = ReminderStatus.APPROVED
    } else if (denyReminderRegex.containsMatchIn(cleanContent)) {
        val matchResult = denyReminderRegex.find(cleanContent)!!
        parseReminderString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        reminderStatus = ReminderStatus.DENIED
    }

    return CoachMessageParsed(
        cleanContent = cleanContent,
        proposedNoteText = proposedNoteText,
        noteStatus = noteStatus,
        proposedFileName = proposedFileName,
        fileStatus = fileStatus,
        proposedListName = proposedListName,
        proposedListItems = proposedListItems,
        listStatus = listStatus,
        proposedReminderTitle = proposedReminderTitle,
        proposedReminderTime = proposedReminderTime,
        reminderStatus = reminderStatus
    )
}


@HiltViewModel
class CoachViewModel @Inject constructor(
    private val userListRepository: UserListRepository,
    private val reminderRepository: ReminderRepository,
    private val syncManager: com.notel.notel.data.sync.SyncManager,
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

    @OptIn(ExperimentalCoroutinesApi::class)
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
                        fileStatus = parsed.fileStatus,
                        proposedListName = parsed.proposedListName,
                        proposedListItems = parsed.proposedListItems,
                        listStatus = parsed.listStatus,
                        proposedReminderTitle = parsed.proposedReminderTitle,
                        proposedReminderTime = parsed.proposedReminderTime,
                        reminderStatus = parsed.reminderStatus
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
    }

    fun approveProposedList(messageId: String, listName: String, items: List<String>) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch
                
                // 1. Create list and add items
                val createdList = userListRepository.createList(listName)
                items.forEach { itemText ->
                    userListRepository.addItem(createdList.id, itemText)
                }
                
                // Force data sync
                syncManager.pushProfileData()

                // 2. Update status in SQLite to APPROVED_LIST
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace("[PROPOSE_LIST:", "[APPROVED_LIST:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }

                // 3. Insert confirmation message
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Awesome! I've created the list \"$listName\" with ${items.size} items."
                    )
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun denyProposedList(messageId: String) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch

                // 1. Update status in SQLite to DENIED_LIST
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace("[PROPOSE_LIST:", "[DENIED_LIST:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }

                // 2. Insert confirmation message
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Okay, I won't create that list."
                    )
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun approveProposedReminder(messageId: String, title: String, timeStr: String?) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch

                // 1. Parse HH:MM into hour/minute
                val parts = timeStr?.split(":") ?: emptyList()
                val hour = parts.getOrNull(0)?.toIntOrNull() ?: 9
                val minute = parts.getOrNull(1)?.toIntOrNull() ?: 0

                // 2. Create reminder via repository
                reminderRepository.addReminder(
                    Reminder(
                        title = title,
                        type = "FIXED",
                        fixedHour = hour,
                        fixedMinute = minute
                    )
                )

                // 3. Update tag in SQLite to APPROVED_REMINDER
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace("[PROPOSE_REMINDER:", "[APPROVED_REMINDER:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }

                // 4. Confirmation message
                val formattedTime = try {
                    val parts = timeStr?.split(":") ?: emptyList()
                    val hour = parts.getOrNull(0)?.toIntOrNull()
                    val minute = parts.getOrNull(1)?.toIntOrNull()
                    if (hour != null && minute != null) {
                        val amPm = if (hour < 12) "AM" else "PM"
                        val h12 = when (hour % 12) { 0 -> 12; else -> hour % 12 }
                        "$h12:${String.format("%02d", minute)} $amPm"
                    } else {
                        timeStr
                    }
                } catch (e: Exception) {
                    timeStr
                }
                val timeLabel = if (formattedTime != null) " at $formattedTime" else ""
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Done! I've set a reminder for \"$title\"$timeLabel."
                    )
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun denyProposedReminder(messageId: String) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch

                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace("[PROPOSE_REMINDER:", "[DENIED_REMINDER:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }

                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Okay, I won't set that reminder."
                    )
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun deleteCurrentSession(onDeleted: () -> Unit) {
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

    // Pending attachment: a file that has been extracted but NOT yet sent.
    // The UI shows it as a chip in the input area until the user hits Send.
    private val _pendingAttachment = MutableStateFlow<PendingUploadFile?>(null)
    val pendingAttachment: StateFlow<PendingUploadFile?> = _pendingAttachment.asStateFlow()

    fun clearPendingAttachment() {
        _pendingAttachment.value = null
    }

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

    /**
     * Attaches a file to the pending input area WITHOUT sending.
     * Extracts the text and stores it as a [pendingAttachment] chip.
     * The user can add their own text and then hit Send to include it.
     */
    fun attachFile(uri: android.net.Uri, contentResolver: android.content.ContentResolver) {
        viewModelScope.launch {
            try {
                // 1. Read file metadata and bytes
                val fileName = getFileName(uri, contentResolver) ?: "unknown_file"
                val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
                val fileBytes = contentResolver.openInputStream(uri)?.use { stream ->
                    stream.readBytes()
                } ?: throw Exception("Could not read file content")
                val base64 = android.util.Base64.encodeToString(fileBytes, android.util.Base64.NO_WRAP)

                // 2. Show a transient extraction indicator (not a persistent chat message)
                val loadingId = UUID.randomUUID().toString()
                _loadingMessage.value = CoachMessage(id = loadingId, role = "coach", content = "Reading $fileName...", isLoading = true)

                // 3. Extract text
                val extractionResult = geminiService.processDocumentFile(mimeType, base64)
                _loadingMessage.value = null

                extractionResult.fold(
                    onSuccess = { extractedText ->
                        // Stage as pending attachment — do NOT send yet
                        val attachment = PendingUploadFile(
                            name = fileName,
                            mimeType = mimeType,
                            base64Data = base64,
                            extractedText = extractedText
                        )
                        pendingFiles[fileName] = attachment
                        _pendingAttachment.value = attachment
                    },
                    onFailure = { error ->
                        _loadingMessage.value = CoachMessage(
                            id = loadingId,
                            role = "coach",
                            content = "Couldn't read that file: ${error.message}",
                            isLoading = false
                        )
                    }
                )
            } catch (e: Exception) {
                _loadingMessage.value = CoachMessage(
                    id = UUID.randomUUID().toString(),
                    role = "coach",
                    content = "An error occurred while reading the file: ${e.message}",
                    isLoading = false
                )
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
        // Allow sending if there is either typed text OR a pending attachment
        val attachment = _pendingAttachment.value
        if (text.isBlank() && attachment == null) return

        val userMsgId = UUID.randomUUID().toString()

        // Build the final message content: file block (if any) + optional user text
        val userText = buildString {
            if (attachment != null) {
                append("📄 Uploaded file: ${attachment.name}\n\n${attachment.extractedText}")
                if (text.isNotBlank()) {
                    append("\n\n")
                    append(text.trim())
                }
            } else {
                append(text.trim())
            }
        }

        // Clear the staged attachment immediately
        _pendingAttachment.value = null

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
            } else if (lastMsg.listStatus == ListStatus.PENDING && lastMsg.proposedListName != null) {
                val lowerText = userText.lowercase()
                if (lowerText == "approve" || lowerText == "yes" || lowerText == "save" || lowerText == "save it" || lowerText == "save that" || lowerText == "create" || lowerText == "create it" || lowerText == "create that") {
                    approveProposedList(lastMsg.id, lastMsg.proposedListName, lastMsg.proposedListItems)
                    return
                } else if (lowerText == "deny" || lowerText == "no" || lowerText == "don't save" || lowerText == "don't create" || lowerText == "cancel" || lowerText == "no don't create") {
                    denyProposedList(lastMsg.id)
                    return
                }
            } else if (lastMsg.reminderStatus == ReminderStatus.PENDING && lastMsg.proposedReminderTitle != null) {
                val lowerText = userText.lowercase()
                if (lowerText == "yes" || lowerText == "set it" || lowerText == "set" || lowerText == "create" || lowerText == "add" || lowerText == "sure" || lowerText == "ok") {
                    approveProposedReminder(lastMsg.id, lastMsg.proposedReminderTitle, lastMsg.proposedReminderTime)
                    return
                } else if (lowerText == "no" || lowerText == "cancel" || lowerText == "don't" || lowerText == "don't set") {
                    denyProposedReminder(lastMsg.id)
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
                val dbEntities = coachMessageDao.getMessagesForSessionDirect(sessionId)
                val currentHistory = dbEntities.map {
                    CoachMessageDto(
                        id = it.id,
                        sessionId = sessionId,
                        role = it.role,
                        content = it.content,
                        timestamp = it.timestamp
                    )
                }
                
                val baseUserCtx = preferences.userContext.first()
                val actionInstructions = """
                    SYSTEM RULES FOR PROPOSING ACTIONS:

                    LISTS: If the user mentions lists, tasks, items to buy, check off, do, pack, or track, helpfully ask if they'd like to turn it into a list. Format: [PROPOSE_LIST:ListName|Item1|Item2|Item3|...]
                    Example: [PROPOSE_LIST:Packing List|T-shirts|Socks|Toothbrush]

                    REMINDERS: If the user mentions wanting to be reminded of something, wanting to remember something at a certain time, or asks you to set a reminder, propose a reminder. Format: [PROPOSE_REMINDER:Reminder Title|HH:MM]
                    Use 24-hour format for the time. Example: [PROPOSE_REMINDER:Take medication|08:00]
                    If no specific time is mentioned, suggest a reasonable time based on context.

                    Only include ONE action tag per response. Do not include markdown formatting inside the brackets.
                """.trimIndent()
                val enrichedUserCtx = if (baseUserCtx.isBlank()) actionInstructions else "$baseUserCtx\n\n$actionInstructions"

                val kb = preferences.knowledgeBase.first()
                val recentEntries = logRepository.getRecentEntriesAll(10)

                val result = logRepository.sendCoachMessage(
                    messages = currentHistory,
                    userContext = enrichedUserCtx,
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
