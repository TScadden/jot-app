package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.LogEntry
import kotlinx.coroutines.flow.Flow

@Dao
interface LogEntryDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertEntry(entry: LogEntry): Long

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(entries: List<LogEntry>)

    @Update
    suspend fun updateEntry(entry: LogEntry)

    @Delete
    suspend fun deleteEntry(entry: LogEntry)

    @Query("SELECT * FROM log_entries ORDER BY timestamp DESC")
    fun getAllEntries(): Flow<List<LogEntry>>

    @Query("SELECT * FROM log_entries WHERE categoryId = :categoryId ORDER BY timestamp DESC")
    fun getEntriesByCategory(categoryId: Int): Flow<List<LogEntry>>

    @Query("SELECT * FROM log_entries WHERE body LIKE '%' || :query || '%' OR manualText LIKE '%' || :query || '%' ORDER BY timestamp DESC")
    fun searchEntries(query: String): Flow<List<LogEntry>>

    @Query("SELECT * FROM log_entries WHERE categoryId = :categoryId ORDER BY timestamp DESC LIMIT :limit")
    suspend fun getRecentEntries(categoryId: Int, limit: Int = 15): List<LogEntry>

    @Query("SELECT * FROM log_entries WHERE id = :id")
    suspend fun getEntryById(id: Long): LogEntry?

    @Query("SELECT * FROM log_entries ORDER BY timestamp DESC LIMIT :limit")
    suspend fun getRecentEntriesAll(limit: Int = 10): List<LogEntry>

    @Query("SELECT COUNT(*) FROM log_entries")
    suspend fun countEntries(): Int
}
