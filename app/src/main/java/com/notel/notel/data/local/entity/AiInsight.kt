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
    val type: String,
    val entryId: Long? = null,
    val requestId: String? = null
)
