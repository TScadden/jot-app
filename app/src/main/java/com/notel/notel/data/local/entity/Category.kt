package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "categories")
data class Category(
    @PrimaryKey val id: Int,
    val name: String,
    val icon: String,       // Material icon name string
    val colorHex: String,   // e.g. "#FF6B6B"
    val isDefault: Boolean = true,
    val sortOrder: Int = 0,
    val slug: String? = null
) {
    val stableKey: String
        get() = slug ?: when (id) {
            1 -> "heart_rate"
            2 -> "calories"
            3 -> "sleep"
            4 -> "mood"
            5 -> "symptoms"
            6 -> "personal"
            7 -> "general"
            8 -> "medication"
            else -> "custom_${name.lowercase().replace(" ", "_")}"
        }
}
