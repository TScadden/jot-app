package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.KnowledgeDocument
import kotlinx.coroutines.flow.Flow

@Dao
interface KnowledgeDocumentDao {
    @Query("SELECT * FROM knowledge_documents ORDER BY createdAt DESC")
    fun getAllDocuments(): Flow<List<KnowledgeDocument>>

    @Query("SELECT * FROM knowledge_documents WHERE id = :id")
    suspend fun getDocumentById(id: String): KnowledgeDocument?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertDocument(doc: KnowledgeDocument)

    @Delete
    suspend fun deleteDocument(doc: KnowledgeDocument)

    @Query("DELETE FROM knowledge_documents")
    suspend fun deleteAll()
}
