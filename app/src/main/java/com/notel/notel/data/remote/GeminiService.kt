package com.notel.notel.data.remote

import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class GeminiService @Inject constructor(
    private val jotApi: JotApi
) {
    // Map our local models to the network DTOs
    private fun List<LogEntry>.toDto(): List<LogEntryDtoModel> = this.map { 
        LogEntryDtoModel(it.id, it.categoryId, it.body, it.chips, it.manualText, it.timestamp) 
    }
    
    private fun Category.toDto(): CategoryDtoModel = 
        CategoryDtoModel(this.id, this.name, this.icon, this.colorHex, this.isDefault, this.sortOrder)

    suspend fun getSuggestions(
        category: Category,
        recentEntries: List<LogEntry>,
        userContext: String = "",
        knowledgeBase: String = "",
        weatherContext: String? = null
    ): Result<List<String>> {
        return try {
            val response = jotApi.getSuggestions(
                SuggestionsRequest(
                    category = category.toDto(),
                    recentEntries = recentEntries.toDto(),
                    userContext = userContext,
                    knowledgeBase = knowledgeBase,
                    weatherContext = weatherContext
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun generateCategories(
        userContext: String
    ): Result<List<String>> {
        return try {
            val response = jotApi.generateCategories(GenerateCategoriesRequest(userContext))
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getSmartCategorySuggestion(
        recentEntries: List<LogEntry>,
        existingCategories: List<String>
    ): Result<SmartCategorySuggestion?> {
        return try {
            val response = jotApi.getSmartCategorySuggestion(
                SmartCategorySuggestionRequest(
                    recentEntries = recentEntries.toDto(),
                    existingCategories = existingCategories
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getAdvice(
        recentEntries: List<LogEntry>,
        categories: Map<Int, String>,
        userContext: String = "",
        knowledgeBase: String = "",
        pastInsights: String = "",
        fitbitData: String = "",
        habitData: String = "",
        weatherContext: String? = null,
        documents: List<ProcessDocumentRequest> = emptyList()
    ): Result<String> {
        return try {
            val response = jotApi.getAdvice(
                AiRequest(
                    entries = recentEntries.toDto(),
                    categories = categories,
                    userContext = userContext,
                    knowledgeBase = knowledgeBase,
                    pastInsights = pastInsights,
                    fitbitData = fitbitData,
                    habitData = habitData,
                    weatherContext = weatherContext,
                    documents = documents
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getMedicalReportSummary(
        recentEntries: List<LogEntry>,
        categories: Map<Int, String>,
        userContext: String = "",
        knowledgeBase: String = "",
        pastInsights: String = "",
        fitbitData: String = "",
        habitData: String = "",
        bodyLoadHistory: String = "",
        weatherContext: String? = null,
        documents: List<ProcessDocumentRequest> = emptyList()
    ): Result<String> {
        return try {
            val response = jotApi.getReport(
                AiRequest(
                    entries = recentEntries.toDto(),
                    categories = categories,
                    userContext = userContext,
                    knowledgeBase = knowledgeBase,
                    pastInsights = pastInsights,
                    fitbitData = fitbitData,
                    habitData = habitData,
                    bodyLoadHistory = bodyLoadHistory,
                    weatherContext = weatherContext,
                    documents = documents
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getWeeklyRecap(
        recentEntries: List<LogEntry>,
        categories: Map<Int, String>,
        userContext: String = "",
        knowledgeBase: String = "",
        fitbitData: String = "",
        habitData: String = "",
        weatherContext: String? = null,
        documents: List<ProcessDocumentRequest> = emptyList()
    ): Result<String> {
        return try {
            val response = jotApi.getWeeklyRecap(
                AiRequest(
                    entries = recentEntries.toDto(),
                    categories = categories,
                    userContext = userContext,
                    knowledgeBase = knowledgeBase,
                    fitbitData = fitbitData,
                    habitData = habitData,
                    weatherContext = weatherContext,
                    documents = documents
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getDeepResearch(
        recentEntries: List<LogEntry>,
        categories: Map<Int, String>,
        userContext: String = "",
        knowledgeBase: String = "",
        pastInsights: String = "",
        fitbitData: String = "",
        habitData: String = "",
        weatherContext: String? = null,
        documents: List<ProcessDocumentRequest> = emptyList()
    ): Result<String> {
        return try {
            val response = jotApi.getDeepResearch(
                AiRequest(
                    entries = recentEntries.toDto(),
                    categories = categories,
                    userContext = userContext,
                    knowledgeBase = knowledgeBase,
                    pastInsights = pastInsights,
                    fitbitData = fitbitData,
                    habitData = habitData,
                    weatherContext = weatherContext,
                    documents = documents
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getDocumentComparison(
        recentEntries: List<LogEntry>,
        categories: Map<Int, String>,
        userContext: String = "",
        knowledgeBase: String = "",
        pastInsights: String = "",
        fitbitData: String = "",
        habitData: String = "",
        weatherContext: String? = null,
        documents: List<ProcessDocumentRequest> = emptyList()
    ): Result<String> {
        return try {
            val response = jotApi.getDocumentComparison(
                AiRequest(
                    entries = recentEntries.toDto(),
                    categories = categories,
                    userContext = userContext,
                    knowledgeBase = knowledgeBase,
                    pastInsights = pastInsights,
                    fitbitData = fitbitData,
                    habitData = habitData,
                    weatherContext = weatherContext,
                    documents = documents
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun processDocumentFile(
        mimeType: String,
        base64Data: String
    ): Result<String> {
        return try {
            val response = jotApi.processDocument(ProcessDocumentRequest(mimeType, base64Data))
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    suspend fun getBodyLoad(
        recentEntries: List<LogEntry>,
        categories: Map<Int, String>,
        userContext: String = "",
        knowledgeBase: String = "",
        fitbitData: String = "",
        habitData: String = "",
        pastInsights: String = "",
        weatherContext: String? = null,
        documents: List<ProcessDocumentRequest> = emptyList()
    ): Result<BodyLoadResponse> {
        return try {
            val response = jotApi.getBodyLoad(
                AiRequest(
                    entries = recentEntries.toDto(),
                    categories = categories,
                    userContext = userContext,
                    knowledgeBase = knowledgeBase,
                    fitbitData = fitbitData,
                    habitData = habitData,
                    pastInsights = pastInsights,
                    weatherContext = weatherContext,
                    documents = documents
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getBodyLoadEnriched(
        recentEntries: List<LogEntry>,
        categories: Map<Int, String>,
        userContext: String = "",
        knowledgeBase: String = "",
        technicalStats: String = "",
        weatherContext: String? = null
    ): Result<BodyLoadResponse> {
        return try {
            val response = jotApi.getBodyLoadEnriched(
                BodyLoadEnrichedRequest(
                    entries = recentEntries.toDto(),
                    categories = categories,
                    userContext = userContext,
                    knowledgeBase = knowledgeBase,
                    technicalStats = technicalStats,
                    weatherContext = weatherContext
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun classifyAndCleanNote(
        noteText: String,
        categories: Map<Int, String>
    ): Result<ClassifyAndCleanResponse> {
        return try {
            val response = jotApi.classifyAndClean(ClassifyAndCleanRequest(noteText, categories))
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                Result.failure(IOException(response.body()?.error ?: "Unknown API Error"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
