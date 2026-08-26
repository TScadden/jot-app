package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "scheduled_dose_occurrences",
    indices = [
        Index(value = ["medicationId", "scheduledDate"], unique = true)
    ]
)
data class ScheduledDoseOccurrence(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val occurrenceKey: String, // e.g. "med_1_2026-08-25"
    val medicationId: Long,
    val scheduledDate: String, // e.g. "2026-08-25"
    val scheduledTime: String? = null,
    val status: String, // "PENDING", "TAKEN", "SKIPPED", "SNOOZED"
    val actionTimestamp: Long = System.currentTimeMillis(),
    val snoozedUntilTimestamp: Long? = null,
    val associatedLogEntryId: Long? = null,
    val syncState: String = "SAVED_LOCALLY"
)
