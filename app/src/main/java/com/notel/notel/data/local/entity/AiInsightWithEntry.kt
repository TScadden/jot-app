package com.notel.notel.data.local.entity

import androidx.room.Embedded
import androidx.room.Relation

data class AiInsightWithEntry(
    @Embedded val insight: AiInsight,
    @Relation(
        parentColumn = "entryId",
        entityColumn = "id"
    )
    val entry: LogEntry?
)
