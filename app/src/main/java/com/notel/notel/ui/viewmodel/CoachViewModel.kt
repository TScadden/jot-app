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
import android.content.Context
import android.content.ContentValues
import android.provider.CalendarContract
import dagger.hilt.android.qualifiers.ApplicationContext
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
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString

enum class MedicationStatus {
    NONE,
    PENDING,
    APPROVED,
    DENIED
}

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

enum class CalendarEventStatus {
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
    val reminderStatus: ReminderStatus = ReminderStatus.NONE,
    val proposedCalendarTitle: String? = null,
    val proposedCalendarDate: String? = null,
    val proposedCalendarTime: String? = null,
    val proposedCalendarDesc: String? = null,
    val calendarStatus: CalendarEventStatus = CalendarEventStatus.NONE,
    val proposedCalendarDeleteTitle: String? = null,
    val proposedCalendarDeleteDate: String? = null,
    val calendarDeleteStatus: CalendarEventStatus = CalendarEventStatus.NONE,
    val proposedMedications: List<Medication> = emptyList(),
    val medicationStatus: MedicationStatus = MedicationStatus.NONE
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
    val reminderStatus: ReminderStatus,
    val proposedCalendarTitle: String?,
    val proposedCalendarDate: String?,
    val proposedCalendarTime: String?,
    val proposedCalendarDesc: String?,
    val calendarStatus: CalendarEventStatus,
    val proposedCalendarDeleteTitle: String?,
    val proposedCalendarDeleteDate: String?,
    val calendarDeleteStatus: CalendarEventStatus,
    val proposedMedications: List<Medication>,
    val medicationStatus: MedicationStatus
)

fun parseCoachMessageContent(rawContent: String): CoachMessageParsed {
    val proposeRegex = Regex("\\[PROPOSE_NOTE:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val approveRegex = Regex("\\[APPROVED_NOTE:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val denyRegex = Regex("\\[DENIED_NOTE:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

    val proposeFileRegex = Regex("\\[PROPOSE_FILE:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val approveFileRegex = Regex("\\[APPROVED_FILE:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val denyFileRegex = Regex("\\[DENIED_FILE:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

    val proposeListRegex = Regex("\\[PROPOSE_LIST:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val approveListRegex = Regex("\\[APPROVED_LIST:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val denyListRegex = Regex("\\[DENIED_LIST:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

    val proposeReminderRegex = Regex("\\[PROPOSE_REMINDER:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val approveReminderRegex = Regex("\\[APPROVED_REMINDER:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val denyReminderRegex = Regex("\\[DENIED_REMINDER:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

    val proposeCalendarRegex = Regex("\\[PROPOSE_CALENDAR_EVENT:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val approveCalendarRegex = Regex("\\[APPROVED_CALENDAR_EVENT:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val denyCalendarRegex = Regex("\\[DENIED_CALENDAR_EVENT:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

    val proposeDeleteCalendarRegex = Regex("\\[PROPOSE_DELETE_CALENDAR_EVENT:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val approveDeleteCalendarRegex = Regex("\\[APPROVED_DELETE_CALENDAR_EVENT:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val denyDeleteCalendarRegex = Regex("\\[DENIED_DELETE_CALENDAR_EVENT:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

    val proposeMedicationRegex = Regex("\\[PROPOSE_MEDICATION:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val approveMedicationRegex = Regex("\\[APPROVED_MEDICATION:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val denyMedicationRegex = Regex("\\[DENIED_MEDICATION:\\s*([^\\]]+)\\]", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

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

    var proposedCalendarTitle: String? = null
    var proposedCalendarDate: String? = null
    var proposedCalendarTime: String? = null
    var proposedCalendarDesc: String? = null
    var calendarStatus = CalendarEventStatus.NONE

    var proposedCalendarDeleteTitle: String? = null
    var proposedCalendarDeleteDate: String? = null
    var calendarDeleteStatus = CalendarEventStatus.NONE

    var proposedMedications: List<Medication> = emptyList()
    var medicationStatus = MedicationStatus.NONE

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

    fun parseCalendarString(raw: String) {
        val parts = raw.split("|")
        proposedCalendarTitle = parts.getOrNull(0)?.trim()
        proposedCalendarDate = parts.getOrNull(1)?.trim()
        proposedCalendarTime = parts.getOrNull(2)?.trim()
        proposedCalendarDesc = parts.getOrNull(3)?.trim()
    }

    if (proposeCalendarRegex.containsMatchIn(cleanContent)) {
        val matchResult = proposeCalendarRegex.find(cleanContent)!!
        parseCalendarString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        calendarStatus = CalendarEventStatus.PENDING
    } else if (approveCalendarRegex.containsMatchIn(cleanContent)) {
        val matchResult = approveCalendarRegex.find(cleanContent)!!
        parseCalendarString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        calendarStatus = CalendarEventStatus.APPROVED
    } else if (denyCalendarRegex.containsMatchIn(cleanContent)) {
        val matchResult = denyCalendarRegex.find(cleanContent)!!
        parseCalendarString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        calendarStatus = CalendarEventStatus.DENIED
    }

    fun parseCalendarDeleteString(raw: String) {
        val parts = raw.split("|")
        proposedCalendarDeleteTitle = parts.getOrNull(0)?.trim()
        proposedCalendarDeleteDate = parts.getOrNull(1)?.trim()
    }

    if (proposeDeleteCalendarRegex.containsMatchIn(cleanContent)) {
        val matchResult = proposeDeleteCalendarRegex.find(cleanContent)!!
        parseCalendarDeleteString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        calendarDeleteStatus = CalendarEventStatus.PENDING
    } else if (approveDeleteCalendarRegex.containsMatchIn(cleanContent)) {
        val matchResult = approveDeleteCalendarRegex.find(cleanContent)!!
        parseCalendarDeleteString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        calendarDeleteStatus = CalendarEventStatus.APPROVED
    } else if (denyDeleteCalendarRegex.containsMatchIn(cleanContent)) {
        val matchResult = denyDeleteCalendarRegex.find(cleanContent)!!
        parseCalendarDeleteString(matchResult.groupValues[1])
        cleanContent = cleanContent.replace(matchResult.value, "").trim()
        calendarDeleteStatus = CalendarEventStatus.DENIED
    }

    fun parseMedicationString(raw: String): List<Medication> {
        val medsList = mutableListOf<Medication>()
        val items = raw.split(";")
        for (item in items) {
            val parts = item.split("|")
            val name = parts.getOrNull(0)?.trim()
            if (!name.isNullOrBlank()) {
                val startDate = parts.getOrNull(1)?.trim() ?: ""
                val endDate = parts.getOrNull(2)?.trim() ?: ""
                val isPresent = parts.getOrNull(3)?.trim()?.lowercase() == "true"
                medsList.add(
                    Medication(
                        id = java.util.UUID.randomUUID().toString(),
                        name = name,
                        startDate = startDate,
                        endDate = if (isPresent) "Present" else endDate,
                        isPresent = isPresent
                    )
                )
            }
        }
        return medsList
    }

    val proposeMatches = proposeMedicationRegex.findAll(cleanContent).toList()
    if (proposeMatches.isNotEmpty()) {
        val parsedMeds = mutableListOf<Medication>()
        for (match in proposeMatches) {
            parsedMeds.addAll(parseMedicationString(match.groupValues[1]))
            cleanContent = cleanContent.replace(match.value, "")
        }
        cleanContent = cleanContent.trim()
        proposedMedications = parsedMeds
        medicationStatus = MedicationStatus.PENDING
    } else {
        val approveMatches = approveMedicationRegex.findAll(cleanContent).toList()
        if (approveMatches.isNotEmpty()) {
            val parsedMeds = mutableListOf<Medication>()
            for (match in approveMatches) {
                parsedMeds.addAll(parseMedicationString(match.groupValues[1]))
                cleanContent = cleanContent.replace(match.value, "")
            }
            cleanContent = cleanContent.trim()
            proposedMedications = parsedMeds
            medicationStatus = MedicationStatus.APPROVED
        } else {
            val denyMatches = denyMedicationRegex.findAll(cleanContent).toList()
            if (denyMatches.isNotEmpty()) {
                val parsedMeds = mutableListOf<Medication>()
                for (match in denyMatches) {
                    parsedMeds.addAll(parseMedicationString(match.groupValues[1]))
                    cleanContent = cleanContent.replace(match.value, "")
                }
                cleanContent = cleanContent.trim()
                proposedMedications = parsedMeds
                medicationStatus = MedicationStatus.DENIED
            }
        }
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
        reminderStatus = reminderStatus,
        proposedCalendarTitle = proposedCalendarTitle,
        proposedCalendarDate = proposedCalendarDate,
        proposedCalendarTime = proposedCalendarTime,
        proposedCalendarDesc = proposedCalendarDesc,
        calendarStatus = calendarStatus,
        proposedCalendarDeleteTitle = proposedCalendarDeleteTitle,
        proposedCalendarDeleteDate = proposedCalendarDeleteDate,
        calendarDeleteStatus = calendarDeleteStatus,
        proposedMedications = proposedMedications,
        medicationStatus = medicationStatus
    )
}


@HiltViewModel
class CoachViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
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
                        reminderStatus = parsed.reminderStatus,
                        proposedCalendarTitle = parsed.proposedCalendarTitle,
                        proposedCalendarDate = parsed.proposedCalendarDate,
                        proposedCalendarTime = parsed.proposedCalendarTime,
                        proposedCalendarDesc = parsed.proposedCalendarDesc,
                        calendarStatus = parsed.calendarStatus,
                        proposedCalendarDeleteTitle = parsed.proposedCalendarDeleteTitle,
                        proposedCalendarDeleteDate = parsed.proposedCalendarDeleteDate,
                        calendarDeleteStatus = parsed.calendarDeleteStatus,
                        proposedMedications = parsed.proposedMedications,
                        medicationStatus = parsed.medicationStatus
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


    fun approveProposedMedication(messageId: String, proposedMeds: List<Medication>) {
        val sessionId = _currentSessionId.value ?: return
        viewModelScope.launch {
            try {
                // Add to preferences
                val json = preferences.medications.first()
                val currentList = if (json.isNotBlank()) {
                    try {
                        Json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(Medication.serializer()), json).toMutableList()
                    } catch (e: Exception) {
                        e.printStackTrace()
                        mutableListOf()
                    }
                } else {
                    mutableListOf()
                }
                
                // Add new meds and deduplicate by name
                val updatedList = (currentList + proposedMeds).distinctBy { it.name.lowercase().trim() }
                preferences.setMedications(Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(Medication.serializer()), updatedList))

                // Mark the message as approved in SQLite
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace("[PROPOSE_MEDICATION:", "[APPROVED_MEDICATION:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }

                // Add confirmation coach response message
                val medNamesStr = proposedMeds.joinToString(", ") { med ->
                    "${med.name} (Started: ${med.startDate}${if (med.isPresent) ", Present" else ", Ended: ${med.endDate}"})"
                }
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Added medications: $medNamesStr.",
                        isSynced = false
                    )
                )

                // Push to sync manager in background
                viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                    try {
                        syncManager.pushProfileData()
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }
            } catch (e: Exception) {
                // Log or ignore
            }
        }
    }

    fun denyProposedMedication(messageId: String) {
        val sessionId = _currentSessionId.value ?: return
        viewModelScope.launch {
            try {
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_MEDICATION:"), "[DENIED_MEDICATION:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }
            } catch (e: Exception) {
                // Log or ignore
            }
        }
    }

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
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_NOTE:"), "[APPROVED_NOTE:")
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
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_NOTE:"), "[DENIED_NOTE:")
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

                // 2. Update status in SQLite to APPROVED_LIST
                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_LIST:"), "[APPROVED_LIST:")
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

                // Push to sync manager in background
                viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                    try {
                        syncManager.pushProfileData()
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }
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
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_LIST:"), "[DENIED_LIST:")
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
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_REMINDER:"), "[APPROVED_REMINDER:")
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
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_REMINDER:"), "[DENIED_REMINDER:")
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

    fun approveProposedCalendarEvent(messageId: String, title: String, date: String?, timeStr: String?, desc: String?) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch
                val targetEmail = preferences.googleCalendarEmail.first()

                // 1. Find the best WRITABLE calendar for the connected account.
                //    CALENDAR_ACCESS_LEVEL >= 500 (CONTRIBUTOR) = writable.
                //    Read-only calendars (holidays, shared read-only) silently swallow inserts.
                data class CalInfo(val id: Long, val accountName: String, val accountType: String)

                val projection = arrayOf(
                    CalendarContract.Calendars._ID,
                    CalendarContract.Calendars.ACCOUNT_NAME,
                    CalendarContract.Calendars.ACCOUNT_TYPE,
                    CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL
                )

                val candidates = mutableListOf<CalInfo>()
                try {
                    context.contentResolver.query(
                        CalendarContract.Calendars.CONTENT_URI,
                        projection, null, null, null
                    )?.use { cursor ->
                        val idCol = cursor.getColumnIndex(CalendarContract.Calendars._ID)
                        val accNameCol = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_NAME)
                        val accTypeCol = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_TYPE)
                        val accessCol = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
                        while (cursor.moveToNext()) {
                            val id = if (idCol != -1) cursor.getLong(idCol) else continue
                            val accName = if (accNameCol != -1) cursor.getString(accNameCol) ?: "" else ""
                            val accType = if (accTypeCol != -1) cursor.getString(accTypeCol) ?: "" else ""
                            val access = if (accessCol != -1) cursor.getInt(accessCol) else 0
                            if (access >= 500) candidates.add(CalInfo(id, accName, accType))
                        }
                    }
                } catch (e: Exception) { e.printStackTrace() }

                // Prefer the calendar whose account matches the connected email; fall back to first writable
                val best = candidates.firstOrNull { it.accountName.equals(targetEmail, ignoreCase = true) }
                    ?: candidates.firstOrNull()

                if (best == null) {
                    coachMessageDao.insertMessage(CoachMessageEntity(sessionId = sessionId, role = "coach",
                        content = "Could not find a writable calendar. Please ensure Calendar permissions are granted in Settings → Apps → Jot → Permissions."))
                    return@launch
                }

                android.util.Log.d("CalendarResolve", "Inserting to calendarId=${best.id} account=${best.accountName}")

                // 2. Parse date+time to epoch milliseconds

                var startMillis = System.currentTimeMillis()
                if (!date.isNullOrBlank() && !timeStr.isNullOrBlank()) {
                    try {
                        val parsed = try {
                            val format12 = java.text.SimpleDateFormat("yyyy-MM-dd hh:mm a", java.util.Locale.US).apply {
                                timeZone = java.util.TimeZone.getDefault()
                            }
                            format12.parse("$date $timeStr")
                        } catch (e: Exception) {
                            val format24 = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.US).apply {
                                timeZone = java.util.TimeZone.getDefault()
                            }
                            format24.parse("$date $timeStr")
                        }
                        if (parsed != null) {
                            startMillis = parsed.time
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }
                val endMillis = startMillis + 60 * 60 * 1000 // default 1 hour duration

                // 3. Write event via ContentResolver — include ACCOUNT_NAME + ACCOUNT_TYPE
                //    so Google Calendar can associate and sync the event properly.
                val eventValues = ContentValues().apply {
                    put(CalendarContract.Events.DTSTART, startMillis)
                    put(CalendarContract.Events.DTEND, endMillis)
                    put(CalendarContract.Events.TITLE, title)
                    put(CalendarContract.Events.DESCRIPTION, desc ?: "")
                    put(CalendarContract.Events.CALENDAR_ID, best.id)
                    put(CalendarContract.Events.EVENT_TIMEZONE, java.util.TimeZone.getDefault().id)
                }

                val eventUri = context.contentResolver.insert(
                    CalendarContract.Events.CONTENT_URI
                        .buildUpon()
                        .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "false")
                        .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, best.accountName)
                        .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, best.accountType)
                        .build(),
                    eventValues
                )

                if (eventUri != null) {
                    // Update tag in SQLite to APPROVED_CALENDAR_EVENT
                    val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                    val targetEntity = dbEntities.find { it.id == messageId }
                    if (targetEntity != null) {
                        val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_CALENDAR_EVENT:"), "[APPROVED_CALENDAR_EVENT:")
                        coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                    }

                    // Add confirmation message
                    val dateLabel = if (!date.isNullOrBlank()) " on $date" else ""
                    val timeLabel = if (!timeStr.isNullOrBlank()) " at $timeStr" else ""
                    coachMessageDao.insertMessage(
                        CoachMessageEntity(
                            sessionId = sessionId,
                            role = "coach",
                            content = "Done! \"$title\" has been added to your Google Calendar${dateLabel}${timeLabel}. It should appear in your Google Calendar app shortly."
                        )
                    )
                } else {
                    coachMessageDao.insertMessage(
                        CoachMessageEntity(
                            sessionId = sessionId,
                            role = "coach",
                            content = "The calendar insert returned no URI — this usually means WRITE_CALENDAR permission was denied. Please go to Settings → Apps → Jot → Permissions and enable Calendar access, then try again."
                        )
                    )
                }
            } catch (e: Exception) {
                e.printStackTrace()
                val sessionId = _currentSessionId.value ?: return@launch
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "An error occurred while writing to your calendar: ${e.message}"
                    )
                )
            }
        }
    }

    fun denyProposedCalendarEvent(messageId: String) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch

                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_CALENDAR_EVENT:"), "[DENIED_CALENDAR_EVENT:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }

                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Okay, I won't add that to your calendar."
                    )
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun approveProposedCalendarDeleteEvent(messageId: String, title: String, date: String?) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch

                // 1. Resolve start/end bounds for query
                var selection = "${CalendarContract.Events.TITLE} = ?"
                val selectionArgs = mutableListOf(title)
                
                if (!date.isNullOrBlank()) {
                    try {
                        val format = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).apply {
                            timeZone = java.util.TimeZone.getDefault()
                        }
                        val parsed = format.parse(date)
                        if (parsed != null) {
                            val startOfDay = parsed.time
                            val endOfDay = startOfDay + 24 * 60 * 60 * 1000
                            selection += " AND ${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} < ?"
                            selectionArgs.add(startOfDay.toString())
                            selectionArgs.add(endOfDay.toString())
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }

                // 2. Perform deletion
                val rowsDeleted = context.contentResolver.delete(
                    CalendarContract.Events.CONTENT_URI,
                    selection,
                    selectionArgs.toTypedArray()
                )

                if (rowsDeleted > 0) {
                    // Update tag in SQLite to APPROVED_DELETE_CALENDAR_EVENT
                    val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                    val targetEntity = dbEntities.find { it.id == messageId }
                    if (targetEntity != null) {
                        val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_DELETE_CALENDAR_EVENT:"), "[APPROVED_DELETE_CALENDAR_EVENT:")
                        coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                    }

                    // Add confirmation message
                    val dateLabel = if (!date.isNullOrBlank()) " scheduled for $date" else ""
                    coachMessageDao.insertMessage(
                        CoachMessageEntity(
                            sessionId = sessionId,
                            role = "coach",
                            content = "Successfully deleted \"$title\"$dateLabel from your Google Calendar!"
                        )
                    )
                } else {
                    coachMessageDao.insertMessage(
                        CoachMessageEntity(
                            sessionId = sessionId,
                            role = "coach",
                            content = "Could not find \"$title\" on your Google Calendar to delete."
                        )
                    )
                }
            } catch (e: Exception) {
                e.printStackTrace()
                val sessionId = _currentSessionId.value ?: return@launch
                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "An error occurred while deleting from your calendar: ${e.message}"
                    )
                )
            }
        }
    }

    fun denyProposedCalendarDeleteEvent(messageId: String) {
        viewModelScope.launch {
            try {
                val sessionId = _currentSessionId.value ?: return@launch

                val dbEntities = coachMessageDao.getMessagesForSession(sessionId).first()
                val targetEntity = dbEntities.find { it.id == messageId }
                if (targetEntity != null) {
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_DELETE_CALENDAR_EVENT:"), "[DENIED_DELETE_CALENDAR_EVENT:")
                    coachMessageDao.insertMessage(targetEntity.copy(content = updatedContent, isSynced = false))
                }

                coachMessageDao.insertMessage(
                    CoachMessageEntity(
                        sessionId = sessionId,
                        role = "coach",
                        content = "Okay, I won't delete that event."
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
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_FILE:"), "[APPROVED_FILE:")
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
                    val updatedContent = targetEntity.content.replace(Regex("(?i)\\[PROPOSE_FILE:"), "[DENIED_FILE:")
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
            } else if (lastMsg.medicationStatus == MedicationStatus.PENDING && lastMsg.proposedMedications.isNotEmpty()) {
                val lowerText = userText.lowercase()
                if (lowerText == "yes" || lowerText == "add" || lowerText == "add it" || lowerText == "approve" || lowerText == "save" || lowerText == "sure" || lowerText == "ok") {
                    approveProposedMedication(
                        lastMsg.id,
                        lastMsg.proposedMedications
                    )
                    return
                } else if (lowerText == "no" || lowerText == "cancel" || lowerText == "don't" || lowerText == "don't add") {
                    denyProposedMedication(lastMsg.id)
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
                val isGoogleCalendarConnected = preferences.googleCalendarConnected.first()
                val todayStr = java.text.SimpleDateFormat("EEEE, MMMM dd, yyyy HH:mm", java.util.Locale.US).apply {
                    timeZone = java.util.TimeZone.getDefault()
                }.format(java.util.Date())
                val todayDateOnly = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).apply {
                    timeZone = java.util.TimeZone.getDefault()
                }.format(java.util.Date())

                val calendarEventsContext = getUpcomingCalendarEvents()
                val calendarInstructions = if (isGoogleCalendarConnected) {
                    """
                    CURRENT TIME: The user's current local date and time is $todayStr. Today's date is $todayDateOnly.
                    
                    IMPORTANT DATE RESOLUTION RULES:
                    - "today" = $todayDateOnly
                    - "tomorrow" = the day after $todayDateOnly
                    - "next [weekday]" = the next occurrence of that weekday after today
                    - If the user says "add an event for today" or "schedule something today", use $todayDateOnly as the date — do NOT ask what day they want.
                    - If the user says "add an event" without specifying a day, infer the date from context or use today ($todayDateOnly) as default.
                    
                    $calendarEventsContext
                    
                    CALENDAR EVENTS: Since Google Calendar is connected, you can propose scheduling events, setting appointments, calendar updates, or deletions.
                    Format for Proposing Event: [PROPOSE_CALENDAR_EVENT:Event Title|YYYY-MM-DD|hh:mm AM/PM|Description]
                    Use 12-hour format with AM/PM for the time (e.g. 02:30 PM). Suggest a reasonable date, time, and description based on context if not fully specified.
                    If the user wants changes, simply generate a new revised [PROPOSE_CALENDAR_EVENT:...] tag.
                    
                    Format for Deleting Event: [PROPOSE_DELETE_CALENDAR_EVENT:Event Title|YYYY-MM-DD]
                    If the user wants to cancel or delete an event, propose it using this tag.
                    
                    CRITICAL RULES FOR READING & SCHEDULING EVENTS:
                    1. When discussing or listing read-only calendar events (like those in the context above), DO NOT ALTER THEIR TITLES OR APPEND APP-SPECIFIC PHRASES. Use their exact names (e.g. if the event is "Physical therapy", call it "Physical therapy", not "Physical therapy for ehlers danlos syndrome").
                    2. Use normal 12-hour time format with AM/PM (e.g., "02:30 PM") in your conversational responses.
                    3. When asked "what do I have today", include ALL events on $todayDateOnly regardless of whether they are past or future — the user wants the full day's schedule.
                    """
                } else {
                    """
                    CALENDAR EVENTS: Since Google Calendar is NOT connected yet, if the user asks you to schedule a calendar event or appointment, politely guide them to connect their Google Calendar first in Settings -> Connected Apps. Do NOT output a [PROPOSE_CALENDAR_EVENT:...] tag.
                    """
                }

                val actionInstructions = """
                    SYSTEM RULES FOR PROPOSING ACTIONS:

                    LISTS: If the user mentions lists, tasks, items to buy, check off, do, pack, or track, helpfully ask if they'd like to turn it into a list. Format: [PROPOSE_LIST:ListName|Item1|Item2|Item3|...]
                    Example: [PROPOSE_LIST:Packing List|T-shirts|Socks|Toothbrush]

                    REMINDERS: If the user mentions wanting to be reminded of something, wanting to remember something at a certain time, or asks you to set a reminder, propose a reminder. Format: [PROPOSE_REMINDER:Reminder Title|HH:MM]
                    Use 24-hour format for the time. Example: [PROPOSE_REMINDER:Take medication|08:00]
                    If no specific time is mentioned, suggest a reasonable time based on context.

                    MEDICATIONS: You MUST actively inspect the user's message and the contents of any uploaded files/documents (indicated by "📄 Uploaded file: [filename]\n\n[contents]") for medications. If the user mentions starting, taking, stopping, or updating medications, or if the uploaded document says the user is taking or was taking any medications, you MUST propose adding them.
                    Format: Propose ALL found medications in a single tag by separating them with a semicolon.
                    Each medication format: Name|StartDate|EndDate|isPresent
                    Use 'isPresent' as 'true' if the user is currently taking the medication, or 'false' if they have stopped. If they are currently taking it, the EndDate should be empty.
                    Dates should look like "Jun 2026", "2025-12-05", "Dec 2025" or similar based on context.
                    Example for multiple medications: [PROPOSE_MEDICATION:Pyridostigmine|Jun 2026||true;Metoprolol|Jan 2025|May 2026|false]

                    $calendarInstructions

                    Only include ONE action tag per response. (Note: For multiple medications, combine them into a single [PROPOSE_MEDICATION:...] tag separated by semicolons as shown above). Do not include markdown formatting inside the brackets.
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

    private suspend fun getUpcomingCalendarEvents(): String {
        return try {
            val isGoogleCalendarConnected = preferences.googleCalendarConnected.first()
            if (!isGoogleCalendarConnected) return "No Google Calendar connected."

            // Query ALL events across ALL calendars synced to the device (no VISIBLE filter).
            // Shared/family calendars frequently have VISIBLE=0 in the database but still
            // appear in the Google Calendar app — filtering by VISIBLE was silently dropping them.

            // Date bounds: start from the earlier of local-midnight and UTC-midnight today
            // so that all-day events (stored as UTC-midnight) are never missed.
            val localMidnight = java.util.Calendar.getInstance().apply {
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis

            val utcMidnight = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply {
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }.timeInMillis

            val queryStart = minOf(localMidnight, utcMidnight)
            val queryEnd = localMidnight + 15 * 24 * 60 * 60 * 1000L

            val eventProjection = arrayOf(
                CalendarContract.Events.TITLE,
                CalendarContract.Events.DTSTART,
                CalendarContract.Events.ALL_DAY
            )

            // No calendar ID filter — select everything that is not deleted and falls in range
            val selection = "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ? AND ${CalendarContract.Events.DELETED} != 1"
            val selectionArgs = arrayOf(queryStart.toString(), queryEnd.toString())

            // Formatters: local time for timed events, UTC date-only for all-day events
            val timedFormat = java.text.SimpleDateFormat("yyyy-MM-dd hh:mm a", java.util.Locale.US).apply {
                timeZone = java.util.TimeZone.getDefault()
            }
            val allDayFormat = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).apply {
                timeZone = java.util.TimeZone.getTimeZone("UTC") // all-day DTSTART is stored in UTC
            }

            val eventsList = mutableListOf<String>()
            try {
                context.contentResolver.query(
                    CalendarContract.Events.CONTENT_URI,
                    eventProjection,
                    selection,
                    selectionArgs,
                    "${CalendarContract.Events.DTSTART} ASC"
                )?.use { cursor ->
                    val titleCol = cursor.getColumnIndex(CalendarContract.Events.TITLE)
                    val startCol = cursor.getColumnIndex(CalendarContract.Events.DTSTART)
                    val allDayCol = cursor.getColumnIndex(CalendarContract.Events.ALL_DAY)
                    if (titleCol != -1 && startCol != -1) {
                        while (cursor.moveToNext()) {
                            val title = cursor.getString(titleCol) ?: "Untitled Event"
                            val start = cursor.getLong(startCol)
                            val isAllDay = allDayCol != -1 && cursor.getInt(allDayCol) == 1
                            val formattedDate = if (isAllDay) {
                                allDayFormat.format(java.util.Date(start)) + " (all day)"
                            } else {
                                timedFormat.format(java.util.Date(start))
                            }
                            eventsList.add("- $title on $formattedDate")
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }

            if (eventsList.isEmpty()) {
                "CALENDAR EVENTS (today + next 14 days): No events found."
            } else {
                "CALENDAR EVENTS (today + next 14 days):\n" + eventsList.joinToString("\n")
            }
        } catch (e: Exception) {
            e.printStackTrace()
            "Error querying calendar events: ${e.message}"
        }
    }

    /** Returns the best writable calendar ID to insert events into.
     *  Prefers a calendar owned by the connected email, then any writable calendar. */
    private fun getBestWritableCalendarId(): Long? {
        val targetEmail = try {
            kotlinx.coroutines.runBlocking { preferences.googleCalendarEmail.first() }
        } catch (e: Exception) { "" }

        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.OWNER_ACCOUNT,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL
        )

        var bestId: Long? = null
        try {
            context.contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection, null, null, null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(CalendarContract.Calendars._ID)
                val accountCol = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_NAME)
                val ownerCol = cursor.getColumnIndex(CalendarContract.Calendars.OWNER_ACCOUNT)
                val accessCol = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
                while (cursor.moveToNext()) {
                    val id = if (idCol != -1) cursor.getLong(idCol) else continue
                    val account = if (accountCol != -1) cursor.getString(accountCol) ?: "" else ""
                    val owner = if (ownerCol != -1) cursor.getString(ownerCol) ?: "" else ""
                    val access = if (accessCol != -1) cursor.getInt(accessCol) else 0
                    // Must be at least CONTRIBUTOR access (500) to write
                    if (access < 500) continue
                    if (targetEmail.isNotBlank() && (account.equals(targetEmail, ignoreCase = true) || owner.equals(targetEmail, ignoreCase = true))) {
                        bestId = id
                        return@use // found best match
                    }
                    if (bestId == null) bestId = id // take first writable as fallback
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return bestId
    }
}
