package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.CoachMessageEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface CoachMessageDao {
    @Query("SELECT * FROM coach_messages WHERE sessionId = :sessionId ORDER BY timestamp ASC")
    fun getMessagesForSession(sessionId: String): Flow<List<CoachMessageEntity>>

    @Query("SELECT * FROM coach_messages WHERE sessionId = :sessionId ORDER BY timestamp ASC")
    suspend fun getMessagesForSessionDirect(sessionId: String): List<CoachMessageEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertMessage(message: CoachMessageEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertMessages(messages: List<CoachMessageEntity>)

    @Query("UPDATE coach_messages SET isSynced = 1 WHERE id = :id")
    suspend fun markSynced(id: String)
    
    @Query("SELECT * FROM coach_messages WHERE isSynced = 0")
    suspend fun getUnsyncedMessages(): List<CoachMessageEntity>
}
