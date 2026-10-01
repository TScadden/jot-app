package com.notel.notel.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.notel.notel.util.NotificationHelper
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class DebugReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val helper = NotificationHelper(context)

        when (action) {
            "com.notel.notel.TEST_HABIT" -> {
                helper.showHabitReminder()
            }
            "com.notel.notel.TEST_SPIKE" -> {
                helper.showSpikeAlert(102, 72, 30)
            }
            "com.notel.notel.TEST_REMINDER" -> {
                helper.showTestReminder("Drink a glass of water")
            }
        }
    }
}
