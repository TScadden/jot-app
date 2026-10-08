package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.MigraineAttack
import kotlinx.coroutines.flow.Flow

@Dao
interface MigraineAttackDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAttack(attack: MigraineAttack): Long

    @Update
    suspend fun updateAttack(attack: MigraineAttack)

    @Query("SELECT * FROM migraine_attacks WHERE id = :id")
    suspend fun getAttack(id: Long): MigraineAttack?

    @Query("SELECT * FROM migraine_attacks ORDER BY startTimestamp DESC")
    fun getAllAttacks(): Flow<List<MigraineAttack>>

    @Query("SELECT * FROM migraine_attacks WHERE endTimestamp IS NULL ORDER BY startTimestamp DESC LIMIT 1")
    suspend fun getActiveAttack(): MigraineAttack?

    @Query("SELECT * FROM migraine_attacks WHERE startTimestamp >= :sinceMs ORDER BY startTimestamp DESC")
    suspend fun getAttacksSince(sinceMs: Long): List<MigraineAttack>

    @Query("SELECT COUNT(*) FROM migraine_attacks")
    suspend fun countAttacks(): Int
}
