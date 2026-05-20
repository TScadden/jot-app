package com.notel.notel.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.ReminderRepository
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
class BootReceiver : BroadcastReceiver() {

    @Inject lateinit var preferences: NotelPreferences
    @Inject lateinit var reminderRepository: ReminderRepository

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            CoroutineScope(Dispatchers.IO).launch {
                // Restart HR spike monitor if enabled
                if (preferences.hrSpikeAlertsEnabled.first()) {
                    HrSpikeMonitorService.startService(context)
                }
                // Reschedule all active reminders (alarms don't survive reboots)
                reminderRepository.rescheduleAll()
            }
        }
    }
}

