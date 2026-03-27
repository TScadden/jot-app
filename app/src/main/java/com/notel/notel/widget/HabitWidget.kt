package com.notel.notel.widget

import android.content.Context
import android.content.Intent
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.actionStartActivity
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
import java.text.SimpleDateFormat
import java.util.*

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
                    .background(ColorProvider(android.graphics.Color.parseColor("#12122A")))
                    .clickable(actionStartActivity(Intent(context, MainActivity::class.java)))
                    .padding(horizontal = 14.dp, vertical = 10.dp)
            ) {
                Text(
                    text = "Daily Habits · $checkedCount/${habits.size}",
                    style = TextStyle(
                        fontWeight = FontWeight.Bold,
                        color = ColorProvider(android.graphics.Color.WHITE)
                    )
                )
                Spacer(GlanceModifier.height(6.dp))
                if (habits.isEmpty()) {
                    Text(
                        text = "Open Jot to add habits!",
                        style = TextStyle(
                            color = ColorProvider(android.graphics.Color.parseColor("#888888"))
                        )
                    )
                } else {
                    habits.take(6).forEach { habit ->
                        val isDone = today in habit.logs
                        Row(
                            modifier = GlanceModifier
                                .fillMaxWidth()
                                .padding(vertical = 2.dp),
                            verticalAlignment = Alignment.Vertical.CenterVertically
                        ) {
                            Text(
                                text = if (isDone) "✅" else "⬜",
                            )
                            Spacer(GlanceModifier.width(6.dp))
                            Text(
                                text = habit.title,
                                style = TextStyle(
                                    color = ColorProvider(
                                        if (isDone) android.graphics.Color.WHITE
                                        else android.graphics.Color.parseColor("#AAAAAA")
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

class HabitWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = HabitWidget()
}
