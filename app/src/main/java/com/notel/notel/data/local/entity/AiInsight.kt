package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable

@Serializable
@Entity(
    tableName = "ai_insights",
    indices = [
        Index(value = ["entryId"]),
        Index(value = ["requestId"], unique = true)
    ]
)
data class AiInsight(
    @PrimaryKey val id: String,
    val text: String,
    val timestamp: Long,
    val type: String, // e.g. "PATIENT_NOTE", "SUMMARY", "AUDIT"
    val entryId: Long? = null,
    val requestId: String? = null,
    val classification: String = "OBSERVATION", // "OBSERVATION", "CORRELATION", "SUGGESTION"
    val dataUsed: String = "Symptom logs, medication records",
    val dateRangeText: String = "Past 7 days",
    val plainLanguageReason: String = "Observed consistency in daily tracking records.",
    val confidence: Float = 0.85f,
    val feedbackState: String = "NONE", // "NONE", "HELPFUL", "NOT_HELPFUL"
    val isDismissed: Boolean = false
)

