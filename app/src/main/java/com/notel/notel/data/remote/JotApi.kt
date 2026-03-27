package com.notel.notel.data.remote

import kotlinx.serialization.Serializable
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.POST

@Serializable
data class AiRequest(
    val entries: List<LogEntryDtoModel> = emptyList(),
    val categories: Map<Int, String> = emptyMap(),
    val userContext: String? = null,
    val knowledgeBase: String? = null,
    val pastInsights: String? = null,
    val fitbitData: String? = null,
    val habitData: String? = null
)

@Serializable
data class SuggestionsRequest(
    val category: CategoryDtoModel,
    val recentEntries: List<LogEntryDtoModel>,
    val userContext: String? = null,
    val knowledgeBase: String? = null
)

@Serializable
data class ProcessDocumentRequest(
    val mimeType: String,
    val base64Data: String
)

@Serializable
data class GenerateCategoriesRequest(
    val userContext: String
)

@Serializable
data class SmartCategorySuggestionRequest(
    val recentEntries: List<LogEntryDtoModel>,
    val existingCategories: List<String>
)

@Serializable
data class SmartCategorySuggestion(
    val category: String?,
    val reason: String?
)

@Serializable
data class AiResponse<T>(
    val result: T,
    val error: String? = null
)

@Serializable
data class AuthRequest(
    val email: String,
    val password: String
)

@Serializable
data class ForgotPasswordRequest(
    val email: String
)

@Serializable
data class GenericResponse(
    val success: Boolean,
    val message: String? = null,
    val error: String? = null
)


@Serializable
data class AuthResponse(
    val token: String? = null,
    val userId: String? = null,
    val email: String? = null,
    val balance: Float? = null,
    val isUnlimited: Boolean? = null,
    val onboardingComplete: Boolean? = null,
    val error: String? = null
)

// Simplified representations for networking to avoid issues with Room annotations
@Serializable
data class LogEntryDtoModel(
    val id: Long = 0,
    val categoryId: Int,
    val body: String,
    val chips: String,
    val manualText: String,
    val timestamp: Long
)

@Serializable
data class CategoryDtoModel(
    val id: Int = 0,
    val name: String,
    val icon: String? = null,
    val colorHex: String? = null,
    val isDefault: Boolean = false,
    val sortOrder: Int = 0
)

@Serializable
data class SyncEntriesRequest(
    val entries: List<LogEntryDtoModel>
)

@Serializable
data class SyncCategoriesRequest(
    val categories: List<CategoryDtoModel>
)

@Serializable
data class SyncProfileRequest(
    val userContext: String? = null,
    val knowledgeBase: String? = null,
    val processedFiles: String? = null,
    val loggedDays: String? = null,
    val age: Int? = null,
    val heightCm: Float? = null,
    val weightKg: Float? = null,
    val gender: String? = null,
    val onboardingComplete: Boolean? = null,
    val autoAiSuggestions: Boolean? = null,
    val eventCounters: String? = null,
    val counterHistory: String? = null
)

@Serializable
data class InsightDtoModel(
    val id: String,
    val text: String,
    val type: String,
    val timestamp: Long
)

@Serializable
data class SyncInsightsRequest(
    val insights: List<InsightDtoModel>
)

@Serializable
data class SyncResponse(
    val synced: Int? = null,
    val saved: Boolean? = null,
    val error: String? = null
)

@Serializable
data class ProfileDtoModel(
    val userContext: String? = null,
    val knowledgeBase: String? = null,
    val processedFiles: String? = null,
    val loggedDays: String? = null,
    val age: Int? = null,
    val heightCm: Float? = null,
    val weightKg: Float? = null,
    val gender: String? = null,
    val onboardingComplete: Boolean? = null,
    val autoAiSuggestions: Boolean? = null,
    val eventCounters: String? = null,
    val counterHistory: String? = null
)

@Serializable
data class SyncPullResponse(
    val entries: List<LogEntryDtoModel> = emptyList(),
    val categories: List<CategoryDtoModel> = emptyList(),
    val profile: ProfileDtoModel? = null,
    val insights: List<InsightDtoModel> = emptyList(),
    val isUnlimited: Boolean? = null,
    val balance: Float? = null
)

@Serializable
data class BillingVerificationRequest(
    val productId: String,
    val purchaseToken: String,
    val quantity: Int = 1
)

@Serializable
data class BillingVerificationResponse(
    val success: Boolean,
    val balance: Float? = null,
    val error: String? = null
)

// ── Habit Data Models ──────────────────────────────────────
@Serializable
data class HabitDtoModel(
    val id: String,
    val title: String,
    val target_time: String? = "Anytime",
    val created_at: String? = null,
    val logs: List<String> = emptyList()
)

@Serializable
data class HabitListResponse(
    val habits: List<HabitDtoModel> = emptyList()
)

@Serializable
data class CreateHabitRequest(
    val title: String,
    val target_time: String = "Anytime"
)

@Serializable
data class CreateHabitResponse(
    val habit: HabitDtoModel? = null,
    val error: String? = null
)

@Serializable
data class LogHabitRequest(
    val habit_id: String,
    val completed_date: String,
    val is_completed: Boolean
)

interface JotApi {

    @POST("api/auth/register")
    suspend fun register(@Body request: AuthRequest): Response<AuthResponse>

    @POST("api/auth/login")
    suspend fun login(@Body request: AuthRequest): Response<AuthResponse>

    @POST("api/auth/forgot-password")
    suspend fun forgotPassword(@Body request: ForgotPasswordRequest): Response<GenericResponse>

    @POST("api/ai/suggestions")
    suspend fun getSuggestions(@Body request: SuggestionsRequest): Response<AiResponse<List<String>>>

    @POST("api/ai/generate-categories")
    suspend fun generateCategories(@Body request: GenerateCategoriesRequest): Response<AiResponse<List<String>>>

    @POST("api/ai/smart-category-suggestion")
    suspend fun getSmartCategorySuggestion(@Body request: SmartCategorySuggestionRequest): Response<AiResponse<SmartCategorySuggestion>>

    @POST("api/ai/advice")
    suspend fun getAdvice(@Body request: AiRequest): Response<AiResponse<String>>

    @POST("api/ai/report")
    suspend fun getReport(@Body request: AiRequest): Response<AiResponse<String>>

    @POST("api/ai/weekly-recap")
    suspend fun getWeeklyRecap(@Body request: AiRequest): Response<AiResponse<String>>

    @POST("api/ai/deep-research")
    suspend fun getDeepResearch(@Body request: AiRequest): Response<AiResponse<String>>

    @POST("api/ai/document-comparison")
    suspend fun getDocumentComparison(@Body request: AiRequest): Response<AiResponse<String>>

    @POST("api/ai/process-document")
    suspend fun processDocument(@Body request: ProcessDocumentRequest): Response<AiResponse<String>>

    // ── SYNC ─────────────────────────────────────────────
    @retrofit2.http.GET("api/sync/pull")
    suspend fun pullData(): Response<SyncPullResponse>

    @POST("api/sync/entries")
    suspend fun syncEntries(@Body request: SyncEntriesRequest): Response<SyncResponse>

    @POST("api/sync/categories")
    suspend fun syncCategories(@Body request: SyncCategoriesRequest): Response<SyncResponse>

    @POST("api/sync/profile")
    suspend fun syncProfile(@Body request: SyncProfileRequest): Response<SyncResponse>

    @POST("api/sync/insights")
    suspend fun syncInsights(@Body request: SyncInsightsRequest): Response<SyncResponse>

    // ── BILLING ──────────────────────────────────────────
    @POST("api/billing/verify")
    suspend fun verifyPurchase(@Body request: BillingVerificationRequest): Response<BillingVerificationResponse>

    // ── HABITS ───────────────────────────────────────────
    @retrofit2.http.GET("api/habits")
    suspend fun getHabits(): Response<HabitListResponse>

    @POST("api/habits")
    suspend fun createHabit(@Body request: CreateHabitRequest): Response<CreateHabitResponse>

    @retrofit2.http.DELETE("api/habits/{id}")
    suspend fun deleteHabit(@retrofit2.http.Path("id") id: String): Response<GenericResponse>

    @POST("api/habits/log")
    suspend fun logHabit(@Body request: LogHabitRequest): Response<GenericResponse>
}
