package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable

@Serializable
@Entity(tableName = "medications")
data class Medication(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val uuid: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    val dose: String,
    val frequency: String,
    val timesPerDay: Int = 1,
    val notes: String = "",
    val isArchived: Boolean = false,
    val startedDate: String? = null,
    val endedDate: String? = null,
    val updatedAt: Long = System.currentTimeMillis(),
    val isDeleted: Boolean = false
)
