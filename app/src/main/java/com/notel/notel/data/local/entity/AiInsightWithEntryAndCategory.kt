package com.notel.notel.data.local.entity

import androidx.room.Embedded

data class AiInsightWithEntryAndCategory(
    @Embedded val insight: AiInsight,
    @Embedded(prefix = "entry_") val entry: LogEntry?,
    @Embedded(prefix = "cat_") val category: Category?
)
