package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable

@Serializable
@Entity(tableName = "pinned_templates")
data class PinnedTemplate(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val title: String,
    val categorySlug: String,
    val body: String,
    val chipsJson: String = "[]",
    val sortOrder: Int = 0,
    val isMedication: Boolean = false
)
