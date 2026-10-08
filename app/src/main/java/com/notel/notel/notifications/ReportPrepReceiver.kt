package com.notel.notel.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.notel.notel.data.model.ScheduledReportEvent
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.worker.ReportPrepWorker
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import javax.inject.Inject

/**
 * Tabs Lab: fires at an event's prep moment (Phase 2, WS-H).
 *
 * The alarm is only the timing mechanism — this receiver does no heavy
 * work itself. It enqueues the one-time [ReportPrepWorker] job under the
 * unique name "report-prep-<eventId>" with KEEP semantics, so a duplicate
 * alarm (e.g. re-armed after boot while the original still fires) can
 * never generate two drafts. WorkManager survives process death and
 * retries with backoff; the worker itself falls back to a raw-data draft
 * rather than silently skipping.
 */
@AndroidEntryPoint
class ReportPrepReceiver : BroadcastReceiver() {

    @Inject lateinit var preferences: NotelPreferences

    override fun onReceive(context: Context, intent: Intent) {
        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val eventId = intent.getStringExtra(ReportPrepScheduler.EXTRA_EVENT_ID)
                    ?: return@launch
                if (!preferences.loggedIn.first()) return@launch
                val event = readEvents().firstOrNull { it.id == eventId } ?: return@launch
                if (event.isReminderOnly) return@launch
                // A stale alarm for a long-past event stays silent.
                if (event.dateTimeMs < System.currentTimeMillis() - 24 * 60 * 60 * 1000L) return@launch
                ReportPrepWorker.enqueue(context.applicationContext, eventId)
            } finally {
                pendingResult.finish()
            }
        }
    }

    private suspend fun readEvents(): List<ScheduledReportEvent> {
        return try {
            val raw = preferences.reportEvents.first()
            if (raw.isBlank()) emptyList()
            else Json.decodeFromString(ListSerializer(ScheduledReportEvent.serializer()), raw)
        } catch (_: Exception) {
            emptyList()
        }
    }
}
