package com.notel.notel.data.repository

import android.content.Context
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import com.notel.notel.data.remote.CreateHabitRequest
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.data.remote.JotApi
import com.notel.notel.data.remote.LogHabitRequest
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class HabitRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val api: JotApi,
    private val preferences: com.notel.notel.data.preferences.NotelPreferences
) {
    private val _habits = MutableStateFlow<List<HabitDtoModel>>(emptyList())
    val habits = _habits.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    // Returns today's date string in YYYY-MM-DD format (UTC-safe for daily reset)
    fun todayDateString(): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())

    suspend fun fetchHabits(): Result<Unit> {
        _isLoading.value = true
        return try {
            val response = api.getHabits()
            if (response.isSuccessful) {
                val habits = response.body()?.habits ?: emptyList()
                _habits.value = habits
                // Cache for the home screen widget
                saveWidgetCache(habits)
                Result.success(Unit)
            } else {
                Result.failure(Exception("Failed to load habits: ${response.code()}"))
            }
        } catch (e: Exception) {
            _error.value = e.message
            Result.failure(e)
        } finally {
            _isLoading.value = false
        }
    }

    suspend fun createHabit(title: String, targetTime: String = "Anytime"): Result<HabitDtoModel> {
        return try {
            val response = api.createHabit(CreateHabitRequest(title = title, target_time = targetTime))
            if (response.isSuccessful) {
                val habit = response.body()?.habit ?: return Result.failure(Exception("No habit returned"))
                _habits.value = _habits.value + habit
                
                // Auto-enable habit reminders for the first habit
                preferences.autoEnableHabitReminders()
                
                Result.success(habit)
            } else {
                val msg = "Failed to create habit (${response.code()}). Is the server deployed?"
                _error.value = msg
                Result.failure(Exception(msg))
            }
        } catch (e: Exception) {
            _error.value = e.message
            Result.failure(e)
        }
    }

    suspend fun deleteHabit(habitId: String): Result<Unit> {
        return try {
            val response = api.deleteHabit(habitId)
            if (response.isSuccessful) {
                _habits.value = _habits.value.filter { it.id != habitId }
                Result.success(Unit)
            } else {
                Result.failure(Exception("Failed to delete habit"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun toggleHabitLog(habitId: String, date: String, isCompleted: Boolean): Result<Unit> {
        return try {
            val response = api.logHabit(LogHabitRequest(habit_id = habitId, completed_date = date, is_completed = isCompleted))
            if (response.isSuccessful) {
                // Update local cache optimistically
                _habits.value = _habits.value.map { habit ->
                    if (habit.id == habitId) {
                        val updatedLogs = if (isCompleted) {
                            if (date !in habit.logs) habit.logs + date else habit.logs
                        } else {
                            habit.logs.filter { it != date }
                        }
                        habit.copy(logs = updatedLogs)
                    } else habit
                }
                Result.success(Unit)
            } else {
                Result.failure(Exception("Failed to toggle habit log"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /** Builds a human-readable habit data string for the AI context window */
    fun buildHabitContextForAi(): String {
        val habits = _habits.value
        if (habits.isEmpty()) return ""
        val sb = StringBuilder("HABIT TRACKING LOG:\n")
        habits.forEach { habit ->
            val streak = calculateStreak(habit.logs)
            val completedDates = habit.logs.sorted().joinToString(", ")
            sb.append("- Habit: \"${habit.title}\" (Target: ${habit.target_time})\n")
            sb.append("  Current Streak: $streak day(s)\n")
            sb.append("  Completed Dates: ${completedDates.ifBlank { "None yet" }}\n")
        }
        return sb.toString().trim()
    }

    fun calculateStreak(logs: List<String>): Int {
        if (logs.isEmpty()) return 0
        val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        val sorted = logs.mapNotNull { runCatching { sdf.parse(it) }.getOrNull() }.sortedDescending()
        val today = sdf.parse(todayDateString()) ?: return 0

        var streak = 0
        var expected = today
        for (date in sorted) {
            if (sdf.format(date) == sdf.format(expected)) {
                streak++
                val cal = java.util.Calendar.getInstance()
                cal.time = expected
                cal.add(java.util.Calendar.DAY_OF_YEAR, -1)
                expected = cal.time
            } else break
        }
        return streak
    }
    private fun saveWidgetCache(habits: List<HabitDtoModel>) {
        try {
            val json = Json.encodeToString(habits)
            context.getSharedPreferences("habit_widget_cache", Context.MODE_PRIVATE)
                .edit().putString("habits_json", json).apply()
            // Notify the widget to refresh
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, com.notel.notel.widget.HabitWidgetReceiver::class.java)
            val ids = manager.getAppWidgetIds(component)
            if (ids.isNotEmpty()) {
                manager.notifyAppWidgetViewDataChanged(ids, android.R.id.list)
            }
        } catch (e: Exception) { /* best effort */ }
    }
}
