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
    /**
     * Stable slug for prefs keys and list identity. Falls back to the
     * canonical [DefaultCategories.slugById] mapping when the stored slug is
     * null (older databases predate the slug column backfill).
     */
    val stableKey: String
        get() = slug ?: com.notel.notel.data.local.DefaultCategories.slugById[id]
            ?: "custom_${name.lowercase().replace(" ", "_")}"
}
