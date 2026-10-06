package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.SyncopeEvent
import kotlinx.coroutines.flow.Flow

@Dao
interface SyncopeEventDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertEvent(event: SyncopeEvent): Long

    @Update
    suspend fun updateEvent(event: SyncopeEvent)

    @Query("SELECT * FROM syncope_events ORDER BY timestamp DESC")
    fun getAllEvents(): Flow<List<SyncopeEvent>>

    @Query("SELECT * FROM syncope_events WHERE timestamp >= :sinceMs ORDER BY timestamp DESC")
    suspend fun getEventsSince(sinceMs: Long): List<SyncopeEvent>

    @Query("SELECT COUNT(*) FROM syncope_events")
    suspend fun countEvents(): Int
}
