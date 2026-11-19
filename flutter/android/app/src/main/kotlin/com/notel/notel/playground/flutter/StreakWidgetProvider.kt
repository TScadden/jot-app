package com.notel.notel.playground.flutter

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
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
/// SIZE BUCKETS (Nov 19, 2026, founder: "Make it as small as the
/// Duolingo widget"): ONE provider, ONE picker entry. Each placed
/// instance renders the COMPACT face (~2x1 cells: flame + count,
/// the greeting, a small Bandit peek — and NO subline, per Juno's
/// compact ruling in JUNO-COMPACT-COPY.md) or the BANNER face
/// (the original wide card, subline included) according to its
/// OWN placed size, read from AppWidgetOptions in onUpdate and
/// re-read on every onAppWidgetOptionsChanged — so resizing an
/// existing placed widget between the two sizes re-renders it in
/// place, with no second provider and no picker duplication.
/// Compact when the placed height is under 100dp or the placed
/// width is under 220dp (the banner's text + subline cannot fit
/// below either floor); when a launcher reports no size options
/// the compact face renders — it is the provider's offered
/// default (targetCell 2x1 in streak_widget_info.xml).
///
/// Signed-out / unseeded payload (signed-in flag not a real true,
/// or no count published): the neutral face at the instance's own
/// size — no numbers, ever, mirroring the vitals widget's
/// signed-out discipline.
///
/// Tap opens the app (plain MainActivity launch): the app has no
/// widget-click / deep-link mechanism (no HomeWidget.widgetClicked
/// listener exists in Dart), so there is no streak-screen deep
/// link to wire — recorded in the package report.
///
/// Failure discipline mirrors VitalsWidgetProvider: onUpdate can
/// never throw into the launcher; any failure falls back to the
/// signed-out face (at the instance's size), then to a minimal
/// hardcoded face.
class StreakWidgetProvider : HomeWidgetProvider() {

    companion object {
        const val KEY_SIGNED_IN = "widget_signed_in"
        const val KEY_STREAK_COUNT = "widget_streak_count"
        const val KEY_STREAK_TODAY_DONE = "widget_streak_today_done"
        const val KEY_STREAK_POSE = "widget_streak_pose"
        const val KEY_STREAK_GREETING = "widget_streak_greeting"
        const val KEY_STREAK_SUBLINE = "widget_streak_subline"
        const val FALLBACK_TEXT = "Open Tabs to sign in"

        // Size-bucket floors (dp): below either, the compact face.
        const val COMPACT_MAX_HEIGHT_DP = 100
        const val COMPACT_MAX_WIDTH_DP = 220
    }

    /// The size bucket one placed instance renders in.
    enum class Bucket { COMPACT, BANNER }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { appWidgetId ->
            val bucket = bucketFor(appWidgetManager, appWidgetId)
            val views = try {
                buildViews(context, widgetData, bucket)
            } catch (_: Exception) {
                try {
                    signedOutViews(context, bucket)
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

    /// A resize re-renders the resized instance in its new bucket.
    /// Delegates to the plugin's 3-arg onUpdate, which re-reads
    /// the widget store and calls the 4-arg onUpdate above (where
    /// the bucket is re-read from the now-current options).
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(
            context,
            appWidgetManager,
            appWidgetId,
            newOptions,
        )
        onUpdate(context, appWidgetManager, intArrayOf(appWidgetId))
    }

    /// Bucket for one instance from its AppWidgetOptions: the
    /// launcher-reported minimum width/height in dp. Missing or
    /// zero dimensions read as "no size reported" and fall to the
    /// compact default (the provider's offered 2x1 form).
    private fun bucketFor(
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
    ): Bucket {
        val options = try {
            appWidgetManager.getAppWidgetOptions(appWidgetId)
        } catch (_: Exception) {
            null
        } ?: return Bucket.COMPACT
        val minWidth = options.getInt(
            AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0,
        )
        val minHeight = options.getInt(
            AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0,
        )
        if (minWidth <= 0 && minHeight <= 0) return Bucket.COMPACT
        return if (
            (minHeight in 1 until COMPACT_MAX_HEIGHT_DP) ||
            (minWidth in 1 until COMPACT_MAX_WIDTH_DP)
        ) {
            Bucket.COMPACT
        } else {
            Bucket.BANNER
        }
    }

    private fun buildViews(
        context: Context,
        widgetData: SharedPreferences,
        bucket: Bucket,
    ): RemoteViews {
        val all = widgetData.all
        // Type-tolerant flag read: only a Boolean true counts
        // (fail-closed, same as the vitals provider).
        val signedIn = (all[KEY_SIGNED_IN] as? Boolean) ?: false
        val count = (all[KEY_STREAK_COUNT] as? String) ?: ""
        if (!signedIn || count.isEmpty()) {
            return signedOutViews(context, bucket)
        }
        return when (bucket) {
            Bucket.COMPACT -> compactViews(context, all, count)
            Bucket.BANNER -> bannerViews(context, all, count)
        }
    }

    /// The banner face: flame + count, greeting, subline verbatim,
    /// Bandit peek — the shipped Nov 18 face, unchanged in binding.
    private fun bannerViews(
        context: Context,
        all: Map<String, *>,
        count: String,
    ): RemoteViews {
        val todayDone = (all[KEY_STREAK_TODAY_DONE] as? Boolean) ?: false
        val views = RemoteViews(context.packageName, R.layout.streak_widget)
        bindFlameCountPose(views, all, count, todayDone)
        bindGreeting(views, all)
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

    /// The compact face (Juno ruling, JUNO-COMPACT-COPY.md):
    /// flame + count and the greeting ONLY. The subline key is
    /// deliberately NEVER read or bound here — no truncation path
    /// for the §9b string may exist at this size, in either state.
    private fun compactViews(
        context: Context,
        all: Map<String, *>,
        count: String,
    ): RemoteViews {
        val todayDone = (all[KEY_STREAK_TODAY_DONE] as? Boolean) ?: false
        val views = RemoteViews(
            context.packageName,
            R.layout.streak_widget_compact,
        )
        bindFlameCountPose(views, all, count, todayDone)
        bindGreeting(views, all)
        views.setOnClickPendingIntent(
            R.id.streak_widget_root,
            launchIntent(context),
        )
        return views
    }

    /// Bindings shared by both faces (both layouts carry these
    /// view ids): the count with its state color, the flame by
    /// state, and the Bandit peek bitmap by payload pose.
    private fun bindFlameCountPose(
        views: RemoteViews,
        all: Map<String, *>,
        count: String,
        todayDone: Boolean,
    ) {
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
    }

    /// Greeting slot collapses entirely when empty (Juno §9d) —
    /// same semantics on both faces.
    private fun bindGreeting(views: RemoteViews, all: Map<String, *>) {
        val greeting = (all[KEY_STREAK_GREETING] as? String) ?: ""
        if (greeting.isEmpty()) {
            views.setViewVisibility(R.id.streak_widget_greeting, View.GONE)
        } else {
            views.setViewVisibility(R.id.streak_widget_greeting, View.VISIBLE)
            views.setTextViewText(R.id.streak_widget_greeting, greeting)
        }
    }

    private fun signedOutViews(
        context: Context,
        bucket: Bucket,
    ): RemoteViews {
        val views = RemoteViews(
            context.packageName,
            when (bucket) {
                Bucket.COMPACT -> R.layout.streak_widget_compact_signed_out
                Bucket.BANNER -> R.layout.streak_widget_signed_out
            },
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
