package com.notel.notel.data.repository

import com.notel.notel.data.local.dao.PinnedTemplateDao
import com.notel.notel.data.local.dao.LogEntryDao
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.dao.MedicationDao
import com.notel.notel.data.local.entity.PinnedTemplate
import com.notel.notel.data.local.entity.LogEntry
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TemplateAndDefaultsRepository @Inject constructor(
    private val pinnedTemplateDao: PinnedTemplateDao,
    private val logEntryDao: LogEntryDao,
    private val categoryDao: CategoryDao,
    private val medicationDao: MedicationDao
) {
    fun getAllPinnedTemplates(): Flow<List<PinnedTemplate>> = pinnedTemplateDao.getAllTemplates()

    suspend fun saveTemplate(template: PinnedTemplate): Long {
        return pinnedTemplateDao.insertTemplate(template)
    }

    suspend fun updateTemplate(template: PinnedTemplate) {
        pinnedTemplateDao.updateTemplate(template)
    }

    suspend fun deleteTemplate(template: PinnedTemplate) {
        pinnedTemplateDao.deleteTemplate(template)
    }

    suspend fun reorderTemplates(templates: List<PinnedTemplate>) {
        templates.forEachIndexed { index, t ->
            pinnedTemplateDao.updateTemplate(t.copy(sortOrder = index))
        }
    }

    suspend fun getDeduplicatedRecentSuggestions(limit: Int = 10): List<LogEntry> {
        val raw = logEntryDao.getRecentEntriesAll(limit * 3)
        val activeMeds = medicationDao.getAllMedications().first().filter { !it.isArchived }.map { it.name.lowercase() }.toSet()
        val seen = mutableSetOf<String>()
        val result = mutableListOf<LogEntry>()

        for (entry in raw) {
            val key = "${entry.categoryId}_${entry.body.trim().lowercase()}"
            if (seen.contains(key)) continue
            seen.add(key)

            // If entry is medication type, ensure medication is not archived
            val category = categoryDao.getCategoryById(entry.categoryId)
            if (category?.slug == "medication") {
                val medNameInBody = entry.body.lowercase()
                if (activeMeds.none { medNameInBody.contains(it) }) {
                    continue
                }
            }

            result.add(entry)
            if (result.size >= limit) break
        }
        return result
    }

    suspend fun getHistoricalDosageForMedication(medicationName: String): String? {
        val raw = logEntryDao.getRecentEntriesAll(100)
        val medCat = categoryDao.getCategoryBySlug("medication") ?: return null
        val lowerMed = medicationName.lowercase().trim()

        val lastMedEntry = raw.find { entry ->
            entry.categoryId == medCat.id && entry.body.lowercase().contains(lowerMed)
        } ?: return null

        // Extract dosage (e.g. 500mg, 10ml, 2 tablets)
        val regex = Regex("""\b(\d+(?:\.\d+)?\s*(?:mg|g|ml|mcg|tablets?|capsules?|pills?))\b""", RegexOption.IGNORE_CASE)
        return regex.find(lastMedEntry.body)?.value
    }

    suspend fun getHistoricalIntensityForSymptom(symptomName: String): String? {
        val raw = logEntryDao.getRecentEntriesAll(100)
        val symCat = categoryDao.getCategoryBySlug("symptom") ?: return null
        val lowerSym = symptomName.lowercase().trim()

        val lastSymEntry = raw.find { entry ->
            entry.categoryId == symCat.id && entry.body.lowercase().contains(lowerSym)
        } ?: return null

        // Extract intensity rating (e.g., 6/10, severe, mild)
        val regex = Regex("""\b(\d{1,2}\s*/\s*10|mild|moderate|severe)\b""", RegexOption.IGNORE_CASE)
        return regex.find(lastSymEntry.body)?.value
    }

    suspend fun getLastCategorySlugForEntryType(query: String): String? {
        val raw = logEntryDao.getRecentEntriesAll(50)
        val firstWords = query.trim().split(" ").take(2).joinToString(" ").lowercase()
        val matching = raw.find { it.body.lowercase().contains(firstWords) } ?: return null
        val cat = categoryDao.getCategoryById(matching.categoryId)
        return cat?.slug
    }
}
