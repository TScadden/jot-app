package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.KnowledgeDocument
import kotlinx.coroutines.flow.Flow

@Dao
interface KnowledgeDocumentDao {
    @Query("SELECT * FROM knowledge_documents ORDER BY timestamp DESC")
    fun getAllDocuments(): Flow<List<KnowledgeDocument>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertDocument(doc: KnowledgeDocument): Long

    @Delete
    suspend fun deleteDocument(doc: KnowledgeDocument)

    @Query("DELETE FROM knowledge_documents")
    suspend fun deleteAll()
}
