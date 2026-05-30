package com.notel.notel.data.repository

import com.notel.notel.data.local.dao.UserListDao
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.local.entity.UserListItem
import com.notel.notel.data.sync.SyncManager
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class UserListRepository @Inject constructor(
    private val dao: UserListDao,
    private val syncManager: dagger.Lazy<SyncManager>
) {
    val lists: Flow<List<UserList>> = dao.getAllLists()

    fun getItemsForList(listId: Int): Flow<List<UserListItem>> = dao.getItemsForList(listId)

    suspend fun createList(name: String): UserList {
        val list = UserList(name = name.trim())
        val id = dao.insertList(list).toInt()
        val result = list.copy(id = id)
        try {
            syncManager.get().pushProfileData()
        } catch (e: Exception) {
            // Ignore
        }
        return result
    }

    suspend fun deleteList(list: UserList) {
        dao.deleteList(list)
        try {
            syncManager.get().pushProfileData()
        } catch (e: Exception) {
            // Ignore
        }
    }

    suspend fun addItem(listId: Int, text: String) {
        val item = UserListItem(listId = listId, text = text.trim())
        dao.insertItem(item)
        try {
            syncManager.get().pushProfileData()
        } catch (e: Exception) {
            // Ignore
        }
    }

    suspend fun deleteItem(item: UserListItem) {
        dao.deleteItem(item)
        try {
            syncManager.get().pushProfileData()
        } catch (e: Exception) {
            // Ignore
        }
    }

    suspend fun updateItem(item: UserListItem, newText: String) {
        dao.updateItem(item.copy(text = newText.trim()))
        try {
            syncManager.get().pushProfileData()
        } catch (e: Exception) {
            // Ignore
        }
    }
}
