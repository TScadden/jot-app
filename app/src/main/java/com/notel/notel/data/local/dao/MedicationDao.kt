package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.local.entity.MedicationSideEffectCache
import kotlinx.coroutines.flow.Flow

@Dao
interface MedicationDao {
    @Query("SELECT * FROM medications ORDER BY id DESC")
    fun getAllMedications(): Flow<List<Medication>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertMedication(medication: Medication): Long

    @Delete
    suspend fun deleteMedication(medication: Medication)

    @Query("SELECT * FROM medication_side_effect_cache WHERE medKey = :key LIMIT 1")
    suspend fun getSideEffectCache(key: String): MedicationSideEffectCache?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertSideEffectCache(cache: MedicationSideEffectCache)

    @Query("DELETE FROM medication_side_effect_cache")
    suspend fun clearAllSideEffectCache()

    @Query("DELETE FROM medications WHERE name = :name")
    suspend fun deleteMedicationByName(name: String)
}

