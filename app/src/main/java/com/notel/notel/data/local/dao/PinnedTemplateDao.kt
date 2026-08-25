package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.PinnedTemplate
import kotlinx.coroutines.flow.Flow

@Dao
interface PinnedTemplateDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertTemplate(template: PinnedTemplate): Long

    @Update
    suspend fun updateTemplate(template: PinnedTemplate)

    @Delete
    suspend fun deleteTemplate(template: PinnedTemplate)

    @Query("SELECT * FROM pinned_templates ORDER BY sortOrder ASC, id ASC")
    fun getAllTemplates(): Flow<List<PinnedTemplate>>

    @Query("DELETE FROM pinned_templates")
    suspend fun deleteAll()
}
