package com.notel.notel.data.research

import android.content.Context
import android.util.Log
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * One research entry shown in the Research hub.
 *
 * Entries are bundled as JSON files under app/src/main/assets/research/.
 * To add a new entry, drop another *.json file in that folder — no code
 * changes required. Condition tags must match [com.notel.notel.data.CommonConditionsList.rawList]
 * strings exactly.
 */
@Serializable
data class ResearchEntry(
    val id: String,
    val title: String,
    val summary: String,
    val detail: String,
    val sourceHandle: String,
    val sourceName: String,
    val sourcePlatform: String,
    val sourceVideoTitle: String,
    val videoDurationSeconds: Int,
    val sourceUrl: String,
    val conditionTags: List<String>
)

object ResearchEntryLoader {
    private const val TAG = "ResearchEntryLoader"
    private const val ASSET_DIR = "research"

    private val json = Json { ignoreUnknownKeys = true }

    fun load(context: Context): List<ResearchEntry> {
        val entries = mutableListOf<ResearchEntry>()
        val files = try {
            context.assets.list(ASSET_DIR) ?: emptyArray()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to list research assets", e)
            return emptyList()
        }
        files.filter { it.endsWith(".json") }.sorted().forEach { fileName ->
            try {
                context.assets.open("$ASSET_DIR/$fileName").use { stream ->
                    val raw = stream.bufferedReader().readText()
                    entries.add(json.decodeFromString<ResearchEntry>(raw))
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse research entry: $fileName", e)
            }
        }
        return entries
    }
}
