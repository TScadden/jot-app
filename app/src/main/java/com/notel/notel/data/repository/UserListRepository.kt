package com.notel.notel.data.repository

import android.util.Log
import com.notel.notel.data.local.dao.UserListDao
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.local.entity.UserListItem
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.sync.SyncManager
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.serialization.builtins.SetSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.serializer
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class UserListRepository @Inject constructor(
    private val dao: UserListDao,
    private val syncManager: dagger.Lazy<SyncManager>,
    private val preferences: NotelPreferences
) {
    private val tag = "UserListRepository"

    val lists: Flow<List<UserList>> = dao.getAllLists()

    fun getItemsForList(listId: Int): Flow<List<UserListItem>> = dao.getItemsForList(listId)

    suspend fun createList(name: String): UserList {
        val list = UserList(name = name.trim())
        val id = dao.insertList(list).toInt()
        val result = list.copy(id = id)
        pushProfileAfterMutation("createList")
        return result
    }

    suspend fun deleteList(list: UserList) {
        dao.deleteList(list)
        // Record a tombstone so a stale server copy can't resurrect the deleted list
        // in a later pull. Self-cleaned by the pull merge once the delete propagates.
        recordListTombstone(list.name)
        pushProfileAfterMutation("deleteList")
    }

    suspend fun addItem(listId: Int, text: String) {
        val item = UserListItem(listId = listId, text = text.trim())
        dao.insertItem(item)
        pushProfileAfterMutation("addItem")
    }

    suspend fun deleteItem(item: UserListItem) {
        dao.deleteItem(item)
        pushProfileAfterMutation("deleteItem")
    }

    suspend fun updateItem(item: UserListItem, newText: String) {
        dao.updateItem(item.copy(text = newText.trim()))
        pushProfileAfterMutation("updateItem")
    }

    private suspend fun recordListTombstone(name: String) {
        try {
            val raw = preferences.deletedListNames.first()
            val current = if (raw.isNotBlank()) Json.decodeFromString<Set<String>>(raw) else emptySet()
            preferences.setDeletedListNames(Json.encodeToString(SetSerializer(serializer<String>()), current + name))
        } catch (e: Exception) {
            Log.e(tag, "Failed to record list tombstone for '$name'", e)
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
