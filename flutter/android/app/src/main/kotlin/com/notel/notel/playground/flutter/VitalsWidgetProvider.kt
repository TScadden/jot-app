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
        const val KEY_STREAK = "widget_streak"
        const val KEY_LOGS = "widget_logs"
        const val KEY_SLEEP = "widget_sleep"
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
        val views = if (signedIn) {
            RemoteViews(context.packageName, R.layout.vitals_widget).apply {
                setTextViewText(
                    R.id.widget_heart_rate,
                    textValue(all, KEY_HEART_RATE),
                )
                setTextViewText(
                    R.id.widget_streak,
                    textValue(all, KEY_STREAK),
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
