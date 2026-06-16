package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable

@Entity(tableName = "reminders")
@Serializable
data class Reminder(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val title: String,
    val type: String,           // "FIXED" or "INTERVAL"
    val fixedHour: Int = 12,
    val fixedMinute: Int = 0,
    val intervalHours: Int = 2,
    val intervalMinutes: Int = 0,
    val startHour: Int = 8,
    val startMinute: Int = 0,
    val endHour: Int = 21,
    val endMinute: Int = 0,
    val isEnabled: Boolean = true,
    val daysOfWeekConfig: String = ""
)

@Serializable
data class DayTimeConfig(
    val dayOfWeek: Int,
    val dayName: String,
    val isEnabled: Boolean = false,
    val hour: Int = 8,
    val minute: Int = 0
)
