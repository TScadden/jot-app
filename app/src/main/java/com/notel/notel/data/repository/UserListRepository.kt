package com.notel.notel.data.repository

import com.notel.notel.data.local.dao.UserListDao
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.local.entity.UserListItem
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class UserListRepository @Inject constructor(
    private val dao: UserListDao
) {
    val lists: Flow<List<UserList>> = dao.getAllLists()

    fun getItemsForList(listId: Int): Flow<List<UserListItem>> = dao.getItemsForList(listId)

    suspend fun createList(name: String): UserList {
        val list = UserList(name = name.trim())
        val id = dao.insertList(list).toInt()
        return list.copy(id = id)
    }

    suspend fun deleteList(list: UserList) = dao.deleteList(list)

    suspend fun addItem(listId: Int, text: String) {
        val item = UserListItem(listId = listId, text = text.trim())
        dao.insertItem(item)
    }

    suspend fun deleteItem(item: UserListItem) = dao.deleteItem(item)

    suspend fun updateItem(item: UserListItem, newText: String) =
        dao.updateItem(item.copy(text = newText.trim()))
}
