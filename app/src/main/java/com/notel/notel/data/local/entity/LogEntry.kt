package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "log_entries")
data class LogEntry(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val timestamp: Long = System.currentTimeMillis(),
    val categoryId: Int,
    val body: String,
    val chips: String = "[]",       // JSON array of tapped chip labels
    val manualText: String = "",    // optional free-form addition
    val source: String? = null      // e.g. "Voice AI"
)
