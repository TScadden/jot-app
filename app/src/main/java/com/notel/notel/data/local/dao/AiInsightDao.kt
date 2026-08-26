package com.notel.notel.data.local.dao

import androidx.room.*
import com.notel.notel.data.local.entity.AiInsight
import kotlinx.coroutines.flow.Flow

@Dao
interface AiInsightDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertInsight(insight: AiInsight)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(insights: List<AiInsight>)

    @Query("SELECT * FROM ai_insights ORDER BY timestamp DESC")
    fun getAllInsights(): Flow<List<AiInsight>>

    @Query("SELECT * FROM ai_insights WHERE entryId = :entryId ORDER BY timestamp DESC")
    fun getInsightsForEntry(entryId: Long): Flow<List<AiInsight>>

    @Query("SELECT * FROM ai_insights WHERE requestId = :requestId LIMIT 1")
    suspend fun getInsightByRequestId(requestId: String): AiInsight?

    @Transaction
    @Query("SELECT * FROM ai_insights ORDER BY timestamp DESC")
    fun getAllInsightsWithEntry(): Flow<List<com.notel.notel.data.local.entity.AiInsightWithEntry>>

    @Query("""
        SELECT 
            i.*,
            e.id AS entry_id, e.timestamp AS entry_timestamp, e.categoryId AS entry_categoryId, e.body AS entry_body, e.chips AS entry_chips, e.manualText AS entry_manualText, e.source AS entry_source,
            c.id AS cat_id, c.name AS cat_name, c.icon AS cat_icon, c.colorHex AS cat_colorHex, c.isDefault AS cat_isDefault, c.sortOrder AS cat_sortOrder, c.slug AS cat_slug
        FROM ai_insights i
        LEFT JOIN log_entries e ON i.entryId = e.id
        LEFT JOIN categories c ON e.categoryId = c.id
        ORDER BY i.timestamp DESC
    """)
    fun getAllInsightsWithEntryAndCategory(): Flow<List<com.notel.notel.data.local.entity.AiInsightWithEntryAndCategory>>

    @Query("UPDATE ai_insights SET feedbackState = :feedback WHERE id = :insightId")
    suspend fun updateFeedback(insightId: String, feedback: String)

    @Query("UPDATE ai_insights SET isDismissed = :isDismissed WHERE id = :insightId")
    suspend fun updateDismissed(insightId: String, isDismissed: Boolean)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertInsightEntryCrossRef(crossRef: com.notel.notel.data.local.entity.InsightEntryCrossRef)

    @Query("""
        SELECT e.* FROM log_entries e
        INNER JOIN insight_entry_cross_ref xref ON e.id = xref.entryId
        WHERE xref.insightId = :insightId
        ORDER BY e.timestamp DESC
    """)
    fun getSupportingEntriesForInsight(insightId: String): Flow<List<com.notel.notel.data.local.entity.LogEntry>>

    @Query("SELECT * FROM ai_insights WHERE isDismissed = 0 ORDER BY timestamp DESC LIMIT 1")
    fun getPrimaryActiveInsight(): Flow<AiInsight?>

    @Query("DELETE FROM ai_insights")
    suspend fun deleteAll()
}
