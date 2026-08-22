package com.notel.notel.widget

import android.content.Context
import android.content.Intent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.action.actionParametersOf
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.action.ActionParameters
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.lazy.items
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.*
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.notel.notel.MainActivity
import com.notel.notel.data.remote.HabitDtoModel
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString
import java.text.SimpleDateFormat
import java.util.*
import kotlinx.coroutines.launch
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface WidgetEntryPoint {
    fun habitRepository(): com.notel.notel.data.repository.HabitRepository
}

class HabitWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val prefs = context.getSharedPreferences("habit_widget_cache", Context.MODE_PRIVATE)
        val json = prefs.getString("habits_json", "[]") ?: "[]"
        val today = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
        val habits: List<HabitDtoModel> = try {
            Json { ignoreUnknownKeys = true }.decodeFromString(json)
        } catch (e: Exception) { emptyList() }
        val checkedCount = habits.count { today in it.logs }

        provideContent {
            Column(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .background(ColorProvider(Color(0xFF12122A)))
                    .padding(horizontal = 14.dp, vertical = 10.dp)
            ) {
                Text(
                    text = "Daily Habits · $checkedCount/${habits.size}",
                    style = TextStyle(
                        fontWeight = FontWeight.Bold,
                        color = ColorProvider(Color.White)
                    ),
                    modifier = GlanceModifier.clickable(actionStartActivity(Intent(context, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }))
                )
                Spacer(GlanceModifier.height(6.dp))
                if (habits.isEmpty()) {
                    Text(
                        text = "Open Tabs to add habits!",
                        style = TextStyle(
                            color = ColorProvider(Color(0xFF888888))
                        )
                    )
                } else {
                    LazyColumn(
                        modifier = GlanceModifier.fillMaxWidth().defaultWeight()
                    ) {
                        items(habits) { habit ->
                            val isDone = today in habit.logs
                            val animStreak = prefs.getInt("anim_streak_${habit.id}", 0)
                            
                            Row(
                                modifier = GlanceModifier
                                    .fillMaxWidth()
                                    .padding(vertical = 4.dp)
                                    .clickable(actionRunCallback<ToggleHabitCallback>(
                                        actionParametersOf(ToggleHabitCallback.PARAM_HABIT_ID to habit.id)
                                    )),
                                verticalAlignment = Alignment.Vertical.CenterVertically
                            ) {
                                if (animStreak > 0) {
                                    Text(
                                        text = "🔥 $animStreak",
                                        style = TextStyle(
                                            color = ColorProvider(Color(0xFFE2A123)),
                                            fontWeight = FontWeight.Bold
                                        )
                                    )
                                } else {
                                    Text(
                                        text = if (isDone) "✅" else "⬜",
                                    )
                                    Spacer(GlanceModifier.width(6.dp))
                                    Text(
                                        text = habit.title,
                                        style = TextStyle(
                                            color = ColorProvider(
                                                if (isDone) Color.White
                                                else Color(0xFFAAAAAA)
                                            )
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

class ToggleHabitCallback : ActionCallback {
    companion object {
        val PARAM_HABIT_ID = ActionParameters.Key<String>("param_habit_id")
    }

    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val habitId = parameters[PARAM_HABIT_ID] ?: return
        val entryPoint = EntryPointAccessors.fromApplication(
            context.applicationContext,
            WidgetEntryPoint::class.java
        )
        val repository = entryPoint.habitRepository()
        val today = repository.todayDateString()

        val prefs = context.getSharedPreferences("habit_widget_cache", Context.MODE_PRIVATE)
        val json = prefs.getString("habits_json", "[]") ?: "[]"
        val habits: List<HabitDtoModel> = try {
            Json { ignoreUnknownKeys = true }.decodeFromString(json)
        } catch (e: Exception) { emptyList() }

        val habit = habits.find { it.id == habitId } ?: return
        val isDone = today in habit.logs

        val updatedHabits = habits.map {
            if (it.id == habitId) {
                val newLogs = if (!isDone) {
                    if (today !in it.logs) it.logs + today else it.logs
                } else {
                    it.logs.filter { it != today }
                }
                it.copy(logs = newLogs)
            } else it
        }

        val updatedJson = Json.encodeToString(updatedHabits)
        prefs.edit().putString("habits_json", updatedJson).apply()

        if (!isDone) {
            val newStreak = repository.calculateStreak(habit.logs + today)
            prefs.edit().putInt("anim_streak_$habitId", newStreak).apply()
            HabitWidget().update(context, glanceId)

            kotlinx.coroutines.GlobalScope.launch {
                repository.toggleHabitLog(habitId, today, true)
            }

            // Launch the animation clearing delay in a decoupled coroutine scope so the ActionCallback
            // can finish executing immediately, preventing Android from killing the process during delay()
            kotlinx.coroutines.GlobalScope.launch {
                kotlinx.coroutines.delay(1200L)
                prefs.edit().remove("anim_streak_$habitId").apply()
                HabitWidget().update(context, glanceId)
            }
        } else {
            HabitWidget().update(context, glanceId)
            kotlinx.coroutines.GlobalScope.launch {
                repository.toggleHabitLog(habitId, today, false)
            }
        }
    }
}

class HabitWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = HabitWidget()
}

