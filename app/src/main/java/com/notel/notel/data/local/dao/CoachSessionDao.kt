package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.CoachSession
import kotlinx.coroutines.flow.Flow

@Dao
interface CoachSessionDao {
    @Query("SELECT * FROM coach_sessions ORDER BY updatedAt DESC")
    fun getAllSessions(): Flow<List<CoachSession>>

    @Query("SELECT * FROM coach_sessions WHERE id = :id LIMIT 1")
    suspend fun getSessionById(id: String): CoachSession?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertSession(session: CoachSession)

    @Update
    suspend fun updateSession(session: CoachSession)

    @Delete
    suspend fun deleteSession(session: CoachSession)
    
    @Query("UPDATE coach_sessions SET isSynced = 1 WHERE id = :id")
    suspend fun markSynced(id: String)
    
    @Query("SELECT * FROM coach_sessions WHERE isSynced = 0")
    suspend fun getUnsyncedSessions(): List<CoachSession>
}
