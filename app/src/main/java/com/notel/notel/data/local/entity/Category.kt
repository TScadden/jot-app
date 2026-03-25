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
    val sortOrder: Int = 0
)
