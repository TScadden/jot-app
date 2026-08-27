package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.ScheduledDoseOccurrence
import kotlinx.coroutines.flow.Flow

@Dao
interface ScheduledDoseOccurrenceDao {
    @Query("SELECT * FROM scheduled_dose_occurrences WHERE occurrenceKey = :occurrenceKey LIMIT 1")
    suspend fun getOccurrenceByKey(occurrenceKey: String): ScheduledDoseOccurrence?

    @Query("SELECT * FROM scheduled_dose_occurrences WHERE medicationId = :medicationId AND scheduledDate = :scheduledDate LIMIT 1")
    suspend fun getOccurrence(medicationId: Long, scheduledDate: String): ScheduledDoseOccurrence?

    @Query("SELECT * FROM scheduled_dose_occurrences WHERE scheduledDate = :scheduledDate")
    fun getOccurrencesForDate(scheduledDate: String): Flow<List<ScheduledDoseOccurrence>>

    @Query("SELECT * FROM scheduled_dose_occurrences WHERE scheduledDate = :scheduledDate")
    suspend fun getOccurrencesForDateDirect(scheduledDate: String): List<ScheduledDoseOccurrence>

    @Query("SELECT * FROM scheduled_dose_occurrences WHERE scheduledDate >= :startDate AND scheduledDate <= :endDate")
    fun getOccurrencesInDateRange(startDate: String, endDate: String): Flow<List<ScheduledDoseOccurrence>>

    @Query("SELECT * FROM scheduled_dose_occurrences")
    fun getAllOccurrences(): Flow<List<ScheduledDoseOccurrence>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertOrUpdateOccurrence(occurrence: ScheduledDoseOccurrence): Long

    @Query("DELETE FROM scheduled_dose_occurrences WHERE occurrenceKey = :occurrenceKey")
    suspend fun deleteOccurrenceByKey(occurrenceKey: String)
}
