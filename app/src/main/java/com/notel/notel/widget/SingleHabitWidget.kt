package com.notel.notel.widget

import android.content.Context
import android.content.Intent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.action.actionParametersOf
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.action.ActionParameters
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
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
import androidx.glance.appwidget.GlanceAppWidgetManager

class SingleHabitWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val appWidgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
        val singlePrefs = context.getSharedPreferences("single_habit_widget_prefs", Context.MODE_PRIVATE)
        val habitId = singlePrefs.getString("habit_id_$appWidgetId", null)

        val prefs = context.getSharedPreferences("habit_widget_cache", Context.MODE_PRIVATE)
        val json = prefs.getString("habits_json", "[]") ?: "[]"
        val today = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
        val habits: List<HabitDtoModel> = try {
            Json { ignoreUnknownKeys = true }.decodeFromString(json)
        } catch (e: Exception) { emptyList() }

        val habit = habits.find { it.id == habitId }
        val entryPoint = EntryPointAccessors.fromApplication(
            context.applicationContext,
            WidgetEntryPoint::class.java
        )
        val repository = entryPoint.habitRepository()

        provideContent {
            Column(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .background(ColorProvider(Color(0xFF12122A)))
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.Vertical.CenterVertically,
                horizontalAlignment = Alignment.Horizontal.CenterHorizontally
            ) {
                if (habit == null) {
                    val pickIntent = Intent(context, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                        action = "com.notel.notel.ACTION_SELECT_HABIT_$appWidgetId"
                        putExtra("EXTRA_SELECT_WIDGET_HABIT", true)
                        putExtra("EXTRA_APP_WIDGET_ID", appWidgetId)
                    }
                    Text(
                        text = "Tap to select a habit",
                        style = TextStyle(
                            color = ColorProvider(Color(0xFFE2A123)),
                            fontWeight = FontWeight.Bold
                        ),
                        modifier = GlanceModifier.clickable(actionStartActivity(pickIntent))
                    )
                } else {
                    val isDone = today in habit.logs
                    val animStreak = singlePrefs.getInt("anim_streak_$habitId", 0)
                    val currentStreak = repository.calculateStreak(habit.logs)

                    Row(
                        modifier = GlanceModifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp)
                            .clickable(actionRunCallback<ToggleSingleHabitCallback>(
                                actionParametersOf(ToggleSingleHabitCallback.PARAM_HABIT_ID to habit.id)
                            )),
                        verticalAlignment = Alignment.Vertical.CenterVertically,
                        horizontalAlignment = Alignment.Horizontal.CenterHorizontally
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
                            Text(text = if (isDone) "✅" else "⬜")
                            Spacer(GlanceModifier.width(8.dp))
                            Column {
                                Text(
                                    text = habit.title,
                                    style = TextStyle(
                                        color = ColorProvider(
                                            if (isDone) Color.White else Color(0xFFAAAAAA)
                                        ),
                                        fontWeight = FontWeight.Bold
                                    )
                                )
                                if (currentStreak > 0) {
                                    Text(
                                        text = "🔥 $currentStreak day streak",
                                        style = TextStyle(
                                            color = ColorProvider(Color(0xFFE2A123)),
                                            fontSize = 12.sp
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

    suspend fun update(context: Context, appWidgetId: Int) {
        try {
            val glanceId = GlanceAppWidgetManager(context).getGlanceIdBy(appWidgetId)
            update(context, glanceId)
        } catch (e: Exception) { /* best effort */ }
    }
}

class ToggleSingleHabitCallback : ActionCallback {
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

        val singlePrefs = context.getSharedPreferences("single_habit_widget_prefs", Context.MODE_PRIVATE)

        if (!isDone) {
            val newStreak = repository.calculateStreak(habit.logs + today)
            singlePrefs.edit().putInt("anim_streak_$habitId", newStreak).apply()
            
            SingleHabitWidget().update(context, glanceId)

            kotlinx.coroutines.GlobalScope.launch {
                repository.toggleHabitLog(habitId, today, true)
            }

            kotlinx.coroutines.delay(1200L)
            singlePrefs.edit().remove("anim_streak_$habitId").apply()
            SingleHabitWidget().update(context, glanceId)
        } else {
            SingleHabitWidget().update(context, glanceId)
            kotlinx.coroutines.GlobalScope.launch {
                repository.toggleHabitLog(habitId, today, false)
            }
        }
    }
}

class SingleHabitWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SingleHabitWidget()
}
