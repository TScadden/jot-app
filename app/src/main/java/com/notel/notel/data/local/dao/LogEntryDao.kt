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

    @Query("""
        UPDATE log_entries
        SET categoryId = :categoryId,
            chips = :chips,
            updatedAt = :updatedAt,
            syncState = 'DIRTY'
        WHERE id = :entryId
    """)
    suspend fun updateEntryCategory(
        entryId: Long,
        categoryId: Int,
        chips: String,
        updatedAt: Long
    )

    @Query("""
        UPDATE log_entries
        SET body = :body,
            manualText = :manualText,
            updatedAt = :updatedAt,
            syncState = 'DIRTY'
        WHERE id = :entryId
    """)
    suspend fun updateEntryText(
        entryId: Long,
        body: String,
        manualText: String,
        updatedAt: Long
    )

    @Query("UPDATE log_entries SET syncState = :syncState WHERE id = :entryId AND updatedAt = :expectedUpdatedAt")
    suspend fun markSyncedIfUnchanged(entryId: Long, expectedUpdatedAt: Long, syncState: com.notel.notel.data.local.entity.EntrySyncState = com.notel.notel.data.local.entity.EntrySyncState.SYNCED): Int

    @Query("SELECT * FROM log_entries WHERE syncState = 'DIRTY'")
    suspend fun getDirtyEntries(): List<LogEntry>

    @Query("SELECT * FROM log_entries WHERE id = :id")
    suspend fun getEntryById(id: Long): LogEntry?

    @Query("SELECT * FROM log_entries WHERE id = :id")
    fun getEntryByIdFlow(id: Long): Flow<LogEntry?>

    @Query("SELECT * FROM log_entries ORDER BY timestamp DESC LIMIT :limit")
    suspend fun getRecentEntriesAll(limit: Int = 10): List<LogEntry>

    @Query("SELECT COUNT(*) FROM log_entries")
    suspend fun countEntries(): Int

    @Query("SELECT COUNT(*) FROM log_entries WHERE timestamp >= :since")
    suspend fun getEntryCountSince(since: Long): Int

    @Query("SELECT COUNT(*) FROM log_entries WHERE timestamp >= :start AND timestamp <= :end")
    suspend fun getEntryCountInRange(start: Long, end: Long): Int

    @Query("SELECT * FROM log_entries WHERE timestamp >= :start AND timestamp <= :end ORDER BY timestamp DESC")
    suspend fun getRecentEntriesInRange(start: Long, end: Long): List<LogEntry>

    @Query("SELECT * FROM log_entries WHERE timestamp <= :end ORDER BY timestamp DESC LIMIT :limit")
    suspend fun getRecentEntriesBefore(end: Long, limit: Int = 5): List<LogEntry>

    @Query("SELECT * FROM log_entries WHERE timestamp >= :start AND timestamp <= :end ORDER BY timestamp DESC")
    suspend fun getEntriesInDateRangeDirect(start: Long, end: Long): List<LogEntry>
}
