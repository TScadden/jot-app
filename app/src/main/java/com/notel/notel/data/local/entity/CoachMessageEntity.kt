package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.UUID

@Entity(
    tableName = "coach_messages",
    foreignKeys = [
        ForeignKey(
            entity = CoachSession::class,
            parentColumns = ["id"],
            childColumns = ["sessionId"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [Index(value = ["sessionId"])]
)
data class CoachMessageEntity(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val sessionId: String,
    val role: String, // "user" or "coach"
    val content: String,
    val timestamp: Long = System.currentTimeMillis(),
    val isSynced: Boolean = false
)
