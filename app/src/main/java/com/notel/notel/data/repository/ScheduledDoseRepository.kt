package com.notel.notel.data.repository

import androidx.room.withTransaction
import com.notel.notel.data.local.NotelDatabase
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.ScheduledDoseOccurrence
import com.notel.notel.ui.viewmodel.ActionStatus
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ScheduledDoseRepository @Inject constructor(
    private val db: NotelDatabase,
    private val logRepository: LogRepository
) {
    private val scheduledDoseOccurrenceDao = db.scheduledDoseOccurrenceDao()

    suspend fun recordDoseAction(
        medicationUuid: String = "",
        medicationId: Long,
        medicationName: String,
        medicationDose: String,
        scheduledDate: String,
        scheduledTime: String,
        action: ActionStatus,
        snoozedUntilMs: Long? = null
    ): ScheduledDoseOccurrence = db.withTransaction {
        val identifier = medicationUuid.trim().ifEmpty { medicationId.toString() }
        val normalizedSlot = scheduledTime.trim().lowercase(java.util.Locale.US).replace("\\s+".toRegex(), "_")
        val occurrenceKey = "med_${identifier}_${scheduledDate}_${normalizedSlot}"
        val existing = scheduledDoseOccurrenceDao.getOccurrenceByKey(occurrenceKey)

        // Idempotency: repeated taps do not duplicate log entries or occurrences
        if (existing?.status == action.name) {
            return@withTransaction existing
        }

        var logId: Long? = existing?.associatedLogEntryId

        if (action == ActionStatus.TAKEN) {
            if (logId == null) {
                val log = LogEntry(
                    categoryId = 8, // Medication category
                    body = "Took $medicationName${if (medicationDose.isNotBlank()) " $medicationDose" else ""}",
                    chips = "[]",
                    manualText = "",
                    timestamp = System.currentTimeMillis()
                )
                logId = logRepository.insertEntry(log)
            }
        } else if (action == ActionStatus.SKIPPED) {
            if (logId != null) {
                val existingLog = db.logEntryDao().getEntryById(logId)
                if (existingLog != null) {
                    val updatedLog = existingLog.copy(
                        body = "[Corrected to Skipped] ${existingLog.body}"
                    )
                    db.logEntryDao().updateEntry(updatedLog)
                }
                logId = null
            }
        }

        val occurrence = ScheduledDoseOccurrence(
            id = existing?.id ?: 0L,
            occurrenceKey = occurrenceKey,
            medicationId = medicationId,
            scheduledDate = scheduledDate,
            scheduledTime = scheduledTime,
            status = action.name,
            actionTimestamp = System.currentTimeMillis(),
            snoozedUntilTimestamp = if (action == ActionStatus.SNOOZED) (snoozedUntilMs ?: existing?.snoozedUntilTimestamp) else null,
            associatedLogEntryId = logId,
            syncState = "SAVED_LOCALLY"
        )

        scheduledDoseOccurrenceDao.insertOrUpdateOccurrence(occurrence)
        occurrence
    }
}
