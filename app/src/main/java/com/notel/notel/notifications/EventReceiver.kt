package com.notel.notel.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.notel.notel.util.NotificationHelper

class EventReceiver : BroadcastReceiver() {
    companion object {
        const val EXTRA_EVENT_NAME = "event_name"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val eventName = intent.getStringExtra(EXTRA_EVENT_NAME) ?: return
        NotificationHelper(context).showEventNotification(eventName)
    }
}
