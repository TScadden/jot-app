package com.notel.notel.data.local.entity

import kotlinx.serialization.Serializable

@Serializable
data class AiInsight(
    val id: String,
    val text: String,
    val timestamp: Long,
    val type: String
)
