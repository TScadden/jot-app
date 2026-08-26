package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "insight_entry_cross_ref",
    primaryKeys = ["insightId", "entryId"],
    indices = [
        Index(value = ["entryId"])
    ]
)
data class InsightEntryCrossRef(
    val insightId: String,
    val entryId: Long
)
