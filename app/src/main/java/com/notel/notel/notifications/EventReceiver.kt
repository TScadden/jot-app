package com.notel.notel.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.util.NotificationHelper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class EventReceiver : BroadcastReceiver() {
    companion object {
        const val EXTRA_EVENT_NAME = "event_name"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val eventName = intent.getStringExtra(EXTRA_EVENT_NAME) ?: return
        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val prefs = NotelPreferences(context)
                val enabled = prefs.eventReminderEnabled.first()
                if (enabled) {
                    NotificationHelper(context).showEventNotification(eventName)
                }
            } finally {
                pendingResult.finish()
            }
        }
    }
}
