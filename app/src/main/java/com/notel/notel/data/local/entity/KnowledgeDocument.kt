package com.notel.notel.data.local.entity

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "knowledge_documents")
data class KnowledgeDocument(
    @PrimaryKey val id: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    val mimeType: String,
    val filePath: String,
    val createdAt: Long = System.currentTimeMillis(),
    val extractedText: String? = null
)
