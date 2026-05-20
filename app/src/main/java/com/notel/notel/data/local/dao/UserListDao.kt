package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.local.entity.UserListItem
import kotlinx.coroutines.flow.Flow

@Dao
interface UserListDao {

    // ── Lists ──────────────────────────────────────────────────────────────────

    @Query("SELECT * FROM user_lists ORDER BY createdAt ASC")
    fun getAllLists(): Flow<List<UserList>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertList(list: UserList): Long

    @Delete
    suspend fun deleteList(list: UserList)

    // ── Items ──────────────────────────────────────────────────────────────────

    @Query("SELECT * FROM user_list_items WHERE listId = :listId ORDER BY sortOrder ASC, id ASC")
    fun getItemsForList(listId: Int): Flow<List<UserListItem>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertItem(item: UserListItem): Long

    @Delete
    suspend fun deleteItem(item: UserListItem)

    @Update
    suspend fun updateItem(item: UserListItem)

    @Query("SELECT COUNT(*) FROM user_list_items WHERE listId = :listId")
    suspend fun countItemsForList(listId: Int): Int

    @Query("DELETE FROM user_lists")
    suspend fun clearAllLists()

    @Query("DELETE FROM user_list_items")
    suspend fun clearAllListItems()
}
