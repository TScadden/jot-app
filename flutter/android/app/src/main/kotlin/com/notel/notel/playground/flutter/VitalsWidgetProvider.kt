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
///
/// Round 59 — the flame cell carries the strip's active calories,
/// exactly like the in-app VitalsStrip (Round 50 put streak days
/// there). [KEY_CALORIES] keeps the Round 50 wire value
/// "widget_streak": an opaque storage identifier shared with the
/// layout's view id and already-placed widgets' stores — only the
/// VALUE stored under it changed meaning, to the strip's field.
///
/// Round 52 hardening (behavior + design tokens unchanged):
/// - `onUpdate` can never throw into the launcher: any failure
///   falls back to the signed-out face (zero data dependencies),
///   and if even that fails, to a minimal hardcoded RemoteViews —
///   an exception must never surface as a launcher error state.
/// - Prefs reads are type-tolerant: values are read via
///   `SharedPreferences.all` and coerced, so a future writer-side
///   encoding drift (e.g. a value landing as a non-String) renders
///   instead of throwing a ClassCastException. The signed-in flag
///   accepts ONLY a real Boolean; anything else reads as signed
///   out (fail-closed: no previous account's numbers can show).
class VitalsWidgetProvider : HomeWidgetProvider() {

    companion object {
        const val KEY_SIGNED_IN = "widget_signed_in"
        const val KEY_HEART_RATE = "widget_heart_rate"
        const val KEY_CALORIES = "widget_streak"
        const val KEY_LOGS = "widget_logs"
        const val KEY_SLEEP = "widget_sleep"
        // Streak upgrade (D14) — banner keys, matching WidgetSync.
        const val KEY_STREAK_COUNT = "widget_streak_count"
        const val KEY_STREAK_TODAY_DONE = "widget_streak_today_done"
        const val KEY_STREAK_POSE = "widget_streak_pose"
        const val KEY_STREAK_GREETING = "widget_streak_greeting"
        const val KEY_STREAK_SUBLINE = "widget_streak_subline"
        const val PLACEHOLDER = "--"
        const val FALLBACK_TEXT = "Open Tabs to sign in"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { appWidgetId ->
            val views = try {
                buildViews(context, widgetData)
            } catch (_: Exception) {
                // Zero-data-dependency fallback: the signed-out face.
                try {
                    signedOutViews(context)
                } catch (_: Exception) {
                    fallbackViews(context)
                }
            }
            try {
                appWidgetManager.updateAppWidget(appWidgetId, views)
            } catch (_: Exception) {
                // Last resort: push the minimal hardcoded face. If
                // even this fails there is nothing safe left to do —
                // swallow so the launcher never sees an error state.
                try {
                    appWidgetManager.updateAppWidget(
                        appWidgetId,
                        fallbackViews(context),
                    )
                } catch (_: Exception) {
                }
            }
        }
    }

    /// The normal render path (unchanged from Round 50): values face
    /// when signed in, signed-out face otherwise, tap opens the app.
    private fun buildViews(
        context: Context,
        widgetData: SharedPreferences,
    ): RemoteViews {
        val all = widgetData.all
        // Type-tolerant flag read: only a Boolean true counts.
        val signedIn = (all[KEY_SIGNED_IN] as? Boolean) ?: false
        // Streak upgrade (D14): when WidgetSync has published a
        // streak banner (non-empty count), the v2 face renders —
        // banner + the same vitals cells. Without streak fields
        // the original face renders, unchanged.
        val streakCount = (all[KEY_STREAK_COUNT] as? String) ?: ""
        val views = if (signedIn && streakCount.isNotEmpty()) {
            RemoteViews(context.packageName, R.layout.vitals_widget_v2).apply {
                setTextViewText(
                    R.id.widget_heart_rate,
                    textValue(all, KEY_HEART_RATE),
                )
                setTextViewText(
                    R.id.widget_streak,
                    textValue(all, KEY_CALORIES),
                )
                setTextViewText(
                    R.id.widget_logs,
                    textValue(all, KEY_LOGS),
                )
                setTextViewText(
                    R.id.widget_sleep,
                    textValue(all, KEY_SLEEP),
                )
                bindStreakBanner(this, all)
            }
        } else if (signedIn) {
            RemoteViews(context.packageName, R.layout.vitals_widget).apply {
                setTextViewText(
                    R.id.widget_heart_rate,
                    textValue(all, KEY_HEART_RATE),
                )
                setTextViewText(
                    R.id.widget_streak,
                    textValue(all, KEY_CALORIES),
                )
                setTextViewText(
                    R.id.widget_logs,
                    textValue(all, KEY_LOGS),
                )
                setTextViewText(
                    R.id.widget_sleep,
                    textValue(all, KEY_SLEEP),
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
        return views
    }

    /// Streak banner binding (D14 + FOUNDER WIDGET RESTYLE,
    /// Nov 18, 2026). ONE dark navy card in both states — the
    /// restyle superseded the purple-gradient celebrate face.
    /// The only state differences are the flame-row count color
    /// (grey while today is open, orange #FF7A50 once done), the
    /// headline/sub-line strings (preformatted verbatim by Dart:
    /// "Hey {name}." + the projected line, or the founder's
    /// "See you tomorrow!" + "Day {N} is locked in."), and the
    /// peek EXPRESSION drawable (bandit_full = peek, eyes open;
    /// bandit_cheer = cheer peek, eyes closed/fists up — the done
    /// rotation alternates them by day-of-year, chosen in Dart).
    /// The greeting slot is GONE entirely when the greeting
    /// string is empty (Juno §9d — collapsed, never left blank).
    private fun bindStreakBanner(
        views: RemoteViews,
        all: Map<String, *>,
    ) {
        val todayDone = (all[KEY_STREAK_TODAY_DONE] as? Boolean) ?: false
        views.setTextViewText(
            R.id.widget_streak_flame_count,
            (all[KEY_STREAK_COUNT] as? String) ?: "",
        )
        views.setTextColor(
            R.id.widget_streak_flame_count,
            if (todayDone) 0xFFFF7A50.toInt() else 0xFF8E97B8.toInt(),
        )
        val pose = (all[KEY_STREAK_POSE] as? String) ?: "peek"
        val poseRes = when (pose) {
            "peek_cheer" -> R.drawable.bandit_cheer
            else -> R.drawable.bandit_full
        }
        views.setImageViewResource(R.id.widget_bandit_pose, poseRes)
        val greeting = (all[KEY_STREAK_GREETING] as? String) ?: ""
        if (greeting.isEmpty()) {
            views.setViewVisibility(
                R.id.widget_streak_greeting,
                android.view.View.GONE,
            )
        } else {
            views.setViewVisibility(
                R.id.widget_streak_greeting,
                android.view.View.VISIBLE,
            )
            views.setTextViewText(R.id.widget_streak_greeting, greeting)
        }
        views.setTextViewText(
            R.id.widget_streak_subline,
            (all[KEY_STREAK_SUBLINE] as? String) ?: "",
        )
    }

    /// Type-tolerant value read: any non-null stored value renders
    /// via `toString()`; a missing/null value renders the
    /// placeholder. Never throws on an unexpected stored type.
    private fun textValue(
        all: Map<String, *>,
        key: String,
    ): String = all[key]?.toString() ?: PLACEHOLDER

    /// The signed-out face with its tap-to-open intent — the same
    /// views [buildViews] produces for a signed-out payload.
    private fun signedOutViews(context: Context): RemoteViews {
        val views = RemoteViews(
            context.packageName,
            R.layout.vitals_widget_signed_out,
        )
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
        return views
    }

    /// Minimal hardcoded last-resort face: a single TextView on the
    /// widget background drawable (`res/layout/vitals_widget_fallback.xml`
    /// carries no data bindings at all). Used only when every
    /// data-dependent path above has already failed.
    private fun fallbackViews(context: Context): RemoteViews =
        RemoteViews(
            context.packageName,
            R.layout.vitals_widget_fallback,
        ).apply {
            setTextViewText(R.id.widget_fallback_text, FALLBACK_TEXT)
        }
}
