package com.notel.notel.data.repository

import android.content.Context
import com.notel.notel.data.local.dao.ReminderDao
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.notifications.ReminderScheduler
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ReminderRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val dao: ReminderDao
) {
    val reminders: Flow<List<Reminder>> = dao.getAllReminders()

    suspend fun addReminder(reminder: Reminder): Reminder {
        val id = dao.insert(reminder).toInt()
        val saved = reminder.copy(id = id)
        ReminderScheduler.schedule(context, saved)
        return saved
    }

    suspend fun deleteReminder(reminder: Reminder) {
        ReminderScheduler.cancel(context, reminder)
        dao.delete(reminder)
    }

    suspend fun toggleEnabled(reminder: Reminder) {
        val updated = reminder.copy(isEnabled = !reminder.isEnabled)
        dao.update(updated)
        ReminderScheduler.schedule(context, updated)
    }

    suspend fun rescheduleAll() {
        dao.getEnabledReminders().forEach { ReminderScheduler.schedule(context, it) }
    }
}
