package com.notel.notel.data.remote

import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class GeminiService @Inject constructor(
    private val tabsApi: TabsApi
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
            val response = tabsApi.getSuggestions(
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
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun generateCategories(
        userContext: String
    ): Result<List<String>> {
        return try {
            val response = tabsApi.generateCategories(GenerateCategoriesRequest(userContext))
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getSmartCategorySuggestion(
        recentEntries: List<LogEntry>,
        existingCategories: List<String>,
        userContext: String? = null
    ): Result<List<SmartCategorySuggestion>> {
        return try {
            val response = tabsApi.getSmartCategorySuggestion(
                SmartCategorySuggestionRequest(
                    recentEntries = recentEntries.toDto(),
                    existingCategories = existingCategories,
                    userContext = userContext
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun validateCategoryName(name: String): Result<String> {
        return try {
            val response = tabsApi.validateCategory(CategoryValidationRequest(name))
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result.cleaned)
            } else {
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Validation failed"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        errorMessage = json.optString("error", "Validation failed")
                    } catch (e: Exception) {}
                }
                Result.failure(IOException(errorMessage))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun evaluateBodyImpacts(
        entries: List<LogEntry>,
        userContext: String = ""
    ): Result<List<AiBodyImpactItem>> {
        return try {
            val response = tabsApi.evaluateBodyImpacts(
                AiBodyImpactRequest(
                    entries = entries.toDto(),
                    userContext = userContext
                )
            )
            val result = response.body()?.result?.impacts
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                val errorBody = response.errorBody()?.string()
                var errorMessage = "AI Body Impact evaluation failed"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        errorMessage = json.optString("error", "AI Body Impact evaluation failed")
                    } catch (e: Exception) {}
                }
                Result.failure(IOException(errorMessage))
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
            val response = tabsApi.getAdvice(
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
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
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
            val response = tabsApi.getReport(
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
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getMedicalReportSummaryFromSnapshot(
        snapshot: com.notel.notel.data.model.ClinicalReportData
    ): Result<String> {
        return try {
            val dateSpanText = "REPORT RANGE: ${snapshot.range.type.name} (${snapshot.range.durationDays} days)"
            // userHeight is stored in inches (see SyncManager's * 2.54f heightCm conversion); convert so the cm label is truthful.
            val heightCm = String.format(java.util.Locale.US, "%.1f", snapshot.userHeight * 2.54f)
            val profileText = buildString {
                append("Profile Stats: Age ${snapshot.userAge}, Height ${heightCm}cm, Weight ${snapshot.userWeight}lbs, Gender ${snapshot.userGender}\n")
                if (snapshot.conditions.isNotEmpty()) {
                    append("Medical Conditions: ${snapshot.conditions.joinToString(", ")}\n")
                }
                if (snapshot.medications.isNotEmpty()) {
                    append("Active Medications: ${snapshot.medications.joinToString(", ") { "${it.name} ${it.dose} (${it.frequency})" }}\n")
                }
            }

            val healthSummary = buildString {
                if (snapshot.heartRateSeries.isNotEmpty()) {
                    val avgHr = snapshot.heartRateSeries.map { it.second }.average().toInt()
                    append("Avg Heart Rate: $avgHr bpm across ${snapshot.heartRateSeries.size} days. ")
                }
                if (snapshot.sleepSeries.isNotEmpty()) {
                    val avgSleepHours = snapshot.sleepSeries.map { it.second / 60f }.average()
                    append("Avg Sleep: ${String.format(java.util.Locale.US, "%.1f", avgSleepHours)} hrs/night across ${snapshot.sleepSeries.size} days. ")
                }
                if (snapshot.heartRateSpikes.isNotEmpty()) {
                    val totalSpikes = snapshot.heartRateSpikes.sumOf { it.spikeCount }
                    append("Total HR Spikes: $totalSpikes recorded. ")
                }
                if (snapshot.bloodPressureSeries.isNotEmpty()) {
                    val sysAvg = snapshot.bloodPressureSeries.map { it.systolic }.average().toInt()
                    val diaAvg = snapshot.bloodPressureSeries.map { it.diastolic }.average().toInt()
                    append("Blood Pressure Avg: $sysAvg/$diaAvg mmHg across ${snapshot.bloodPressureSeries.size} readings. ")
                }
                if (snapshot.caloriesSeries.isNotEmpty()) {
                    val avgCal = snapshot.caloriesSeries.map { it.second }.average().toInt()
                    append("Avg Calories: $avgCal kcal/day across ${snapshot.caloriesSeries.size} days. ")
                }
                if (snapshot.hrvSeries.isNotEmpty()) {
                    val avgHrv = snapshot.hrvSeries.map { it.second }.average()
                    append("Avg HRV (RMSSD): ${String.format(java.util.Locale.US, "%.1f", avgHrv)} ms across ${snapshot.hrvSeries.size} days. ")
                }
                if (snapshot.deepSleepSeries.isNotEmpty()) {
                    val avgDeepSleepHours = snapshot.deepSleepSeries.map { it.second / 60f }.average()
                    append("Avg Deep Sleep: ${String.format(java.util.Locale.US, "%.1f", avgDeepSleepHours)} hrs/night across ${snapshot.deepSleepSeries.size} days. ")
                }
            }

            val enrichedContext = "${snapshot.userContext}\n\n$dateSpanText\n$profileText"

            // Authoritative per-metric availability so the report model never
            // invents statistics for metrics whose data could not be retrieved.
            val availabilityText = snapshot.sectionMetadata.entries.joinToString("; ") { (key, meta) ->
                val label = key.replaceFirstChar { it.uppercase() }
                val status = if (meta.status == com.notel.notel.data.model.DataSourceStatus.SUCCESS)
                    "Available (${meta.recordCount} records)" else "Unavailable"
                "$label: $status"
            }
            
            // Privacy-safe telemetry logging
            android.util.Log.d(
                "GeminiService",
                "[AI_REPORT_REQUEST] Sending snapshot request: ${snapshot.logEntries.size} logs, " +
                        "${snapshot.conditions.size} conditions, ${snapshot.medications.size} meds, " +
                        "${snapshot.heartRateSeries.size} HR days, ${snapshot.bloodPressureSeries.size} BP logs."
            )

            val response = tabsApi.getReport(
                AiRequest(
                    entries = snapshot.logEntries.toDto(),
                    categories = snapshot.categoriesMap,
                    userContext = enrichedContext,
                    knowledgeBase = snapshot.knowledgeDocuments.joinToString("\n\n").ifBlank { null },
                    fitbitData = healthSummary,
                    bodyLoadHistory = snapshot.bodyLoadHistory.ifBlank { null },
                    dataAvailability = availabilityText.ifBlank { null }
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
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
            val response = tabsApi.getWeeklyRecap(
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
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
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
            val response = tabsApi.getDeepResearch(
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
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
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
            val response = tabsApi.getDocumentComparison(
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
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
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
            val response = tabsApi.processDocument(ProcessDocumentRequest(mimeType, base64Data))
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
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
            val response = tabsApi.getBodyLoad(
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
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getBodyLoadEnriched(
        targetDate: String,
        recentEntries: List<LogEntry>,
        categories: Map<Int, String>,
        userContext: String = "",
        knowledgeBase: String = "",
        fitbitData: String = "",
        habitData: String = "",
        pastInsights: String = "",
        weatherContext: String? = null
    ): Result<BodyLoadResponse> {
        return try {
            val response = tabsApi.getBodyLoadEnriched(
                BodyLoadEnrichedRequest(
                    targetDate = targetDate,
                    entries = recentEntries.toDto(),
                    categories = categories,
                    userContext = userContext,
                    knowledgeBase = knowledgeBase,
                    fitbitData = fitbitData,
                    habitData = habitData,
                    pastInsights = pastInsights,
                    weatherContext = weatherContext
                )
            )
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
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
            val response = tabsApi.classifyAndClean(ClassifyAndCleanRequest(noteText, categories))
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result)
            } else {
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun classifyCoachNoteCategory(
        noteText: String,
        categories: Map<Int, String>
    ): Result<Int> {
        return try {
            val response = tabsApi.classifyCoachNote(ClassifyAndCleanRequest(noteText, categories))
            val result = response.body()?.result
            if (response.isSuccessful && result != null) {
                Result.success(result.categoryId)
            } else {
                val errorBody = response.errorBody()?.string()
                var errorMessage = "Unknown API Error"
                if (errorBody != null) {
                    try {
                        val json = org.json.JSONObject(errorBody)
                        if (json.has("error")) {
                            errorMessage = json.getString("error")
                        } else if (json.has("message")) {
                            errorMessage = json.getString("message")
                        } else {
                            errorMessage = errorBody
                        }
                    } catch (e: Exception) {
                        errorMessage = errorBody
                    }
                }
                Result.failure(IOException(errorMessage))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
