package com.notel.notel.data.repository

import android.content.Context
import android.util.Log
import com.notel.notel.data.local.dao.ReminderDao
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.notifications.ReminderScheduler
import com.notel.notel.data.sync.SyncManager
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.serialization.builtins.SetSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.serializer
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ReminderRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val dao: ReminderDao,
    private val syncManager: dagger.Lazy<SyncManager>,
    private val preferences: NotelPreferences
) {
    private val tag = "ReminderRepository"

    val reminders: Flow<List<Reminder>> = dao.getAllReminders()

    suspend fun addReminder(reminder: Reminder): Reminder {
        val id = dao.insert(reminder).toInt()
        val saved = reminder.copy(id = id)
        ReminderScheduler.schedule(context, saved)
        pushProfileAfterMutation("addReminder")
        return saved
    }

    suspend fun deleteReminder(reminder: Reminder) {
        ReminderScheduler.cancel(context, reminder)
        dao.delete(reminder)
        // Record a tombstone so a stale server copy can't resurrect the deleted reminder
        // in a later pull. Self-cleaned by the pull merge once the delete propagates.
        recordReminderTombstone(reminder.id)
        pushProfileAfterMutation("deleteReminder")
    }

    suspend fun toggleEnabled(reminder: Reminder) {
        val updated = reminder.copy(isEnabled = !reminder.isEnabled)
        dao.update(updated)
        ReminderScheduler.schedule(context, updated)
        pushProfileAfterMutation("toggleEnabled")
    }

    suspend fun rescheduleAll() {
        dao.getEnabledReminders().forEach { ReminderScheduler.schedule(context, it) }
    }

    private suspend fun recordReminderTombstone(id: Int) {
        try {
            val raw = preferences.deletedReminderIds.first()
            val current = if (raw.isNotBlank()) Json.decodeFromString<Set<String>>(raw) else emptySet()
            preferences.setDeletedReminderIds(Json.encodeToString(SetSerializer(serializer<String>()), current + id.toString()))
        } catch (e: Exception) {
            Log.e(tag, "Failed to record reminder tombstone for id $id", e)
        }
    }

    /**
     * Mutation-time push. Failures are logged (never silently swallowed) and marked
     * dirty so the next syncAllData() cycle retries the push and surfaces the outcome.
     */
    private suspend fun pushProfileAfterMutation(op: String) {
        val ok = try {
            syncManager.get().pushProfileData()
        } catch (e: Exception) {
            Log.e(tag, "Profile push after $op threw", e)
            false
        }
        if (!ok) {
            Log.w(tag, "Profile push after $op failed; marked dirty for retry on next sync")
            preferences.setProfilePushDirty(true)
        }
    }
}
