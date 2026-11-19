package com.notel.notel.playground.flutter

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/// Streak home-screen widget (founder finding, Nov 18, 2026: the
/// streak package shipped the banner as in-app UI + a banner face
/// inside the VITALS widget, but no standalone streak widget ever
/// existed in the picker — this provider is it).
///
/// Renders the streak payload Dart's `WidgetSync.pushStreak` saves
/// through the home_widget bridge — the EXISTING keys, verbatim
/// (count / todayDone / pose / name / greeting / subline are
/// preformatted by Dart; nothing is computed or reworded here).
/// One dark navy card in both states, matching the in-app banner:
/// flame grey + count grey while today is open, flame lit + count
/// orange once done; the Bandit peek bitmap (pre-rendered head
/// crop, full nose visible, bottom-edge crop — see
/// res/drawable-nodpi/bandit_peek*.png) sits at the card's bottom
/// edge, the cheer peek only in the done state when the payload
/// pose says so.
///
/// Signed-out / unseeded payload (signed-in flag not a real true,
/// or no count published): the neutral face — no numbers, ever,
/// mirroring the vitals widget's signed-out discipline.
///
/// Tap opens the app (plain MainActivity launch): the app has no
/// widget-click / deep-link mechanism (no HomeWidget.widgetClicked
/// listener exists in Dart), so there is no streak-screen deep
/// link to wire — recorded in the package report.
///
/// Failure discipline mirrors VitalsWidgetProvider: onUpdate can
/// never throw into the launcher; any failure falls back to the
/// signed-out face, then to a minimal hardcoded face.
class StreakWidgetProvider : HomeWidgetProvider() {

    companion object {
        const val KEY_SIGNED_IN = "widget_signed_in"
        const val KEY_STREAK_COUNT = "widget_streak_count"
        const val KEY_STREAK_TODAY_DONE = "widget_streak_today_done"
        const val KEY_STREAK_POSE = "widget_streak_pose"
        const val KEY_STREAK_GREETING = "widget_streak_greeting"
        const val KEY_STREAK_SUBLINE = "widget_streak_subline"
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
                try {
                    signedOutViews(context)
                } catch (_: Exception) {
                    fallbackViews(context)
                }
            }
            try {
                appWidgetManager.updateAppWidget(appWidgetId, views)
            } catch (_: Exception) {
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

    private fun buildViews(
        context: Context,
        widgetData: SharedPreferences,
    ): RemoteViews {
        val all = widgetData.all
        // Type-tolerant flag read: only a Boolean true counts
        // (fail-closed, same as the vitals provider).
        val signedIn = (all[KEY_SIGNED_IN] as? Boolean) ?: false
        val count = (all[KEY_STREAK_COUNT] as? String) ?: ""
        if (!signedIn || count.isEmpty()) {
            return signedOutViews(context)
        }
        val todayDone = (all[KEY_STREAK_TODAY_DONE] as? Boolean) ?: false
        val views = RemoteViews(context.packageName, R.layout.streak_widget)
        views.setTextViewText(R.id.streak_widget_count, count)
        views.setTextColor(
            R.id.streak_widget_count,
            if (todayDone) 0xFFFF7A50.toInt() else 0xFF8E97B8.toInt(),
        )
        views.setImageViewResource(
            R.id.streak_widget_flame,
            if (todayDone) {
                R.drawable.ic_widget_flame
            } else {
                R.drawable.ic_widget_flame_grey
            },
        )
        // Pose selects the done-state peek bitmap; not-done is
        // always the plain peek.
        val pose = (all[KEY_STREAK_POSE] as? String) ?: "peek"
        views.setImageViewResource(
            R.id.streak_widget_bandit,
            if (todayDone && pose == "peek_cheer") {
                R.drawable.bandit_peek_cheer
            } else {
                R.drawable.bandit_peek
            },
        )
        // Greeting slot collapses entirely when empty (Juno §9d).
        val greeting = (all[KEY_STREAK_GREETING] as? String) ?: ""
        if (greeting.isEmpty()) {
            views.setViewVisibility(R.id.streak_widget_greeting, View.GONE)
        } else {
            views.setViewVisibility(R.id.streak_widget_greeting, View.VISIBLE)
            views.setTextViewText(R.id.streak_widget_greeting, greeting)
        }
        views.setTextViewText(
            R.id.streak_widget_subline,
            (all[KEY_STREAK_SUBLINE] as? String) ?: "",
        )
        views.setOnClickPendingIntent(
            R.id.streak_widget_root,
            launchIntent(context),
        )
        return views
    }

    private fun signedOutViews(context: Context): RemoteViews {
        val views = RemoteViews(
            context.packageName,
            R.layout.streak_widget_signed_out,
        )
        views.setOnClickPendingIntent(
            R.id.streak_widget_root,
            launchIntent(context),
        )
        return views
    }

    /// Minimal last-resort face (the vitals fallback layout carries
    /// no data bindings at all).
    private fun fallbackViews(context: Context): RemoteViews =
        RemoteViews(
            context.packageName,
            R.layout.vitals_widget_fallback,
        ).apply {
            setTextViewText(R.id.widget_fallback_text, FALLBACK_TEXT)
        }

    private fun launchIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context,
            1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
