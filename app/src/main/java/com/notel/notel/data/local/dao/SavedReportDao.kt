package com.notel.notel.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.notel.notel.data.local.entity.SavedReport
import kotlinx.coroutines.flow.Flow

@Dao
interface SavedReportDao {
    @Query("SELECT * FROM saved_reports ORDER BY generatedAtMs DESC")
    fun observeAll(): Flow<List<SavedReport>>

    @Query("SELECT * FROM saved_reports WHERE id = :id LIMIT 1")
    suspend fun getById(id: Long): SavedReport?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(report: SavedReport): Long

    @Query("SELECT MAX(version) FROM saved_reports WHERE title = :title AND focusKey = :focusKey")
    suspend fun maxVersionFor(title: String, focusKey: String): Int?

    @Query("DELETE FROM saved_reports WHERE id = :id")
    suspend fun deleteById(id: Long)

    @Query("SELECT COUNT(*) FROM saved_reports")
    suspend fun count(): Int
}
