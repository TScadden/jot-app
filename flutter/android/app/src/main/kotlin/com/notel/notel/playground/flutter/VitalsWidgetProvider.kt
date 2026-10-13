package com.notel.notel.playground.flutter

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/// Round 50 — home-screen vitals widget provider.
///
/// Renders the values face (`res/layout/vitals_widget.xml`) from the
/// preformatted strings the Dart `WidgetSync` saved through the
/// home_widget bridge (the SAME HomeCacheSnapshot Home renders
/// from), or the signed-out face
/// (`res/layout/vitals_widget_signed_out.xml`) when the signed-in
/// flag is absent/false. No numbers are ever computed or invented
/// here — a missing value renders "--", and the signed-out face
/// shows no numbers at all.
///
/// Keys must match `WidgetSync` in
/// `lib/src/data/widget_sync.dart`.
class VitalsWidgetProvider : HomeWidgetProvider() {

    companion object {
        const val KEY_SIGNED_IN = "widget_signed_in"
        const val KEY_HEART_RATE = "widget_heart_rate"
        const val KEY_STREAK = "widget_streak"
        const val KEY_LOGS = "widget_logs"
        const val KEY_SLEEP = "widget_sleep"
        const val PLACEHOLDER = "--"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val signedIn = widgetData.getBoolean(KEY_SIGNED_IN, false)
        appWidgetIds.forEach { appWidgetId ->
            val views = if (signedIn) {
                RemoteViews(context.packageName, R.layout.vitals_widget).apply {
                    setTextViewText(
                        R.id.widget_heart_rate,
                        widgetData.getString(KEY_HEART_RATE, PLACEHOLDER)
                            ?: PLACEHOLDER,
                    )
                    setTextViewText(
                        R.id.widget_streak,
                        widgetData.getString(KEY_STREAK, PLACEHOLDER)
                            ?: PLACEHOLDER,
                    )
                    setTextViewText(
                        R.id.widget_logs,
                        widgetData.getString(KEY_LOGS, PLACEHOLDER)
                            ?: PLACEHOLDER,
                    )
                    setTextViewText(
                        R.id.widget_sleep,
                        widgetData.getString(KEY_SLEEP, PLACEHOLDER)
                            ?: PLACEHOLDER,
                    )
                }
            } else {
                RemoteViews(
                    context.packageName,
                    R.layout.vitals_widget_signed_out,
                )
            }

            // Tapping anywhere on the widget opens the app.
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
