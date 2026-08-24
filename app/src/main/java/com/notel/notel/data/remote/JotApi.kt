package com.notel.notel.data.remote

import kotlinx.serialization.Serializable
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.POST
import retrofit2.http.GET

@Serializable
data class FocusSuggestionsRequest(
    val struggle: String
)

@Serializable
data class FocusSuggestion(
    val title: String,
    val desc: String
)

@Serializable
data class AiRequest(
    val entries: List<LogEntryDtoModel> = emptyList(),
    val categories: Map<Int, String> = emptyMap(),
    val userContext: String? = null,
    val knowledgeBase: String? = null,
    val pastInsights: String? = null,
    val fitbitData: String? = null,
    val habitData: String? = null,
    val bodyLoadHistory: String? = null,
    val weatherContext: String? = null,
    val documents: List<ProcessDocumentRequest> = emptyList()
)

@Serializable
data class SuggestionsRequest(
    val category: CategoryDtoModel,
    val recentEntries: List<LogEntryDtoModel>,
    val userContext: String? = null,
    val knowledgeBase: String? = null,
    val weatherContext: String? = null
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
    val existingCategories: List<String>,
    val userContext: String? = null
)

@Serializable
data class SmartCategorySuggestion(
    val category: String?,
    val reason: String?
)

@Serializable
data class CategoryValidationRequest(
    val categoryName: String
)

@Serializable
data class CategoryValidationResponse(
    val cleaned: String
)

@Serializable
data class BodyLoadEnrichedRequest(
    val targetDate: String? = null,
    val entries: List<LogEntryDtoModel> = emptyList(),
    val categories: Map<Int, String> = emptyMap(),
    val userContext: String? = null,
    val knowledgeBase: String? = null,
    val fitbitData: String? = null,
    val habitData: String? = null,
    val pastInsights: String? = null,
    val weatherContext: String? = null
)

@Serializable
data class BodyLoadResponse(
    var score: Int,
    var factors: List<String> = emptyList(),
    val advice: String? = null,
    val subjectiveImpact: Double = 0.0
)

@Serializable
data class AiResponse<T>(
    val result: T,
    val error: String? = null
)

@Serializable
data class CoachMessageDto(
    val id: String,
    val sessionId: String,
    val role: String,
    val content: String,
    val timestamp: Long
)

@Serializable
data class CoachSessionDto(
    val id: String,
    val title: String,
    val createdAt: Long,
    val updatedAt: Long
)

@Serializable
data class TitleRequest(
    val firstMessage: String
)

@Serializable
data class TitleResponse(
    val title: String
)

@Serializable
data class CoachRequest(
    val messages: List<CoachMessageDto>,
    val userContext: String? = null,
    val knowledgeBase: String? = null,
    val recentEntries: List<LogEntryDtoModel> = emptyList(),
    val bodyLoadHistory: String? = null
)

@Serializable
data class AuthRequest(
    val email: String,
    val password: String
)

@Serializable
data class GoogleAuthRequest(
    val idToken: String,
    val isRegisterMode: Boolean
)

@Serializable
data class ForgotPasswordRequest(
    val email: String
)

@Serializable
data class UpdatePasswordRequest(
    val newPassword: String
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
    val isUnlimited: Boolean? = null,
    val isAdmin: Boolean? = null,
    val onboardingComplete: Boolean? = null,
    val nickname: String? = null,
    val tag: String? = null,
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
data class UserListSyncDto(
    val name: String,
    val items: List<String> = emptyList()
)

@Serializable
data class SyncProfileRequest(
    val userContext: String? = null,
    val knowledgeBase: String? = null,
    val professionalUpdates: String? = null,
    val processedFiles: String? = null,
    val loggedDays: String? = null,
    val age: Int? = null,
    val heightCm: Float? = null,
    val weightKg: Float? = null,
    val gender: String? = null,
    val onboardingComplete: Boolean? = null,
    val autoAiSuggestions: Boolean? = null,
    val eventCounters: String? = null,
    val counterHistory: String? = null,
    val currentStreak: Int? = null,
    val bestStreak: Int? = null,
    val userLists: String? = null,
    val focusState: String? = null,
    val reminders: String? = null,
    val weeklyScore: Int? = null,
    val shareDataWithFriends: Boolean? = null,
    val todaySleepMins: Int? = null,
    val todayAvgHr: Int? = null,
    val todayScore: Int? = null,
    val todaySpikes: Int? = null,
    val todaySleepDebt: Int? = null,
    val hasVisibleBandAsked: Boolean? = null,
    val heartRateHistory: String? = null,
    // Newly synced fields
    val medications: String? = null,
    val conditions: String? = null,
    val bodyLoadRemindersEnabled: Boolean? = null,
    val dailyCupUpdatesEnabled: Boolean? = null,
    val hrSpikeAlertsEnabled: Boolean? = null,
    val spikeThreshold: Int? = null,
    val hrDeltaEnabled: Boolean? = null,
    val spikeDeltaThreshold: Int? = null,
    val habitReminderEnabled: Boolean? = null,
    val projectReminderEnabled: Boolean? = null,
    val eventReminderEnabled: Boolean? = null,
    val infoTileOrder: String? = null
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
data class KnowledgeDocumentDtoModel(
    val id: String,
    val name: String,
    val mimeType: String,
    val fileData: String? = null,
    val createdAt: Long
)

@Serializable
data class SyncDocumentsRequest(
    val documents: List<KnowledgeDocumentDtoModel>
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
    val professionalUpdates: String? = null,
    val processedFiles: String? = null,
    val loggedDays: String? = null,
    val age: Int? = null,
    val heightCm: Float? = null,
    val weightKg: Float? = null,
    val gender: String? = null,
    val onboardingComplete: Boolean? = null,
    val autoAiSuggestions: Boolean? = null,
    val eventCounters: String? = null,
    val counterHistory: String? = null,
    val currentStreak: Int? = null,
    val bestStreak: Int? = null,
    val userLists: String? = null,
    val focusState: String? = null,
    val reminders: String? = null,
    val weeklyScore: Int? = null,
    val shareDataWithFriends: Boolean? = null,
    val todaySleepMins: Int? = null,
    val todayAvgHr: Int? = null,
    val todayScore: Int? = null,
    val todaySpikes: Int? = null,
    val todaySleepDebt: Int? = null,
    val hasVisibleBandAsked: Boolean? = null,
    val heartRateHistory: String? = null,
    // Newly synced fields
    val medications: String? = null,
    val conditions: String? = null,
    val bodyLoadRemindersEnabled: Boolean? = null,
    val dailyCupUpdatesEnabled: Boolean? = null,
    val hrSpikeAlertsEnabled: Boolean? = null,
    val spikeThreshold: Int? = null,
    val hrDeltaEnabled: Boolean? = null,
    val spikeDeltaThreshold: Int? = null,
    val habitReminderEnabled: Boolean? = null,
    val projectReminderEnabled: Boolean? = null,
    val eventReminderEnabled: Boolean? = null,
    val infoTileOrder: String? = null
)

@Serializable
data class SyncPullResponse(
    val entries: List<LogEntryDtoModel> = emptyList(),
    val categories: List<CategoryDtoModel> = emptyList(),
    val profile: ProfileDtoModel? = null,
    val insights: List<InsightDtoModel> = emptyList(),
    val documents: List<KnowledgeDocumentDtoModel> = emptyList(),
    val coachSessions: List<CoachSessionDto> = emptyList(),
    val coachMessages: List<CoachMessageDto> = emptyList(),
    val isUnlimited: Boolean? = null,
    val isAdmin: Boolean? = null,
    val nickname: String? = null,
    val tag: String? = null
)

@Serializable
data class SyncCoachSessionsRequest(
    val sessions: List<CoachSessionDto>
)

@Serializable
data class SyncCoachMessagesRequest(
    val messages: List<CoachMessageDto>
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
    val isUnlimited: Boolean? = null,
    val error: String? = null
)

@Serializable
data class SubscriptionSyncRequest(
    val activeTokens: List<String>
)

@Serializable
data class SubscriptionSyncResponse(
    val success: Boolean,
    val isUnlimited: Boolean
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

@Serializable
data class ClassifyAndCleanRequest(
    val noteText: String,
    val categories: Map<Int, String>
)

@Serializable
data class AiBodyImpactItem(
    val region: String, // e.g. "HEAD", "BACK", "EYES", "LEFT_ARM", "RIGHT_ARM", "ABDOMEN", "LEFT_SIDE", "RIGHT_SIDE", "THIGHS"
    val regionName: String,
    val status: String,
    val details: String,
    val durationMinutes: Int, // AI decided duration in minutes based on medical knowledge/research
    val logId: Long
)

@Serializable
data class AiBodyImpactRequest(
    val entries: List<LogEntryDtoModel>,
    val userContext: String? = null
)

@Serializable
data class AiBodyImpactResponse(
    val impacts: List<AiBodyImpactItem> = emptyList()
)

@Serializable
data class ClassifyAndCleanResponse(
    val cleanedText: String,
    val categoryId: Int
)

@Serializable
data class ClassifyCoachNoteResponse(
    val categoryId: Int
)

@Serializable
data class NicknameCheckResponse(
    val unique: Boolean,
    val error: String? = null
)

@Serializable
data class UpdateNicknameRequest(
    val nickname: String
)

@Serializable
data class UpdateNicknameResponse(
    val success: Boolean,
    val nickname: String? = null,
    val tag: String? = null,
    val error: String? = null
)

@Serializable
data class FriendDto(
    val id: String,
    val nickname: String,
    val tag: String,
    val status: String,
    val level: Int
)

@Serializable
data class FriendDetailDto(
    val friendId: String,
    val nickname: String,
    val tag: String,
    val sharingEnabled: Boolean,
    val todaySleepMins: Int? = null,
    val todayAvgHr: Int? = null,
    val todayScore: Int? = null,
    val todaySpikes: Int? = null,
    val todaySleepDebt: Int? = null
)

@Serializable
data class FriendDetailResponse(
    val success: Boolean,
    val data: FriendDetailDto? = null,
    val error: String? = null
)

@Serializable
data class FriendsListResponse(
    val success: Boolean,
    val friends: List<FriendDto>? = null,
    val error: String? = null
)

@Serializable
data class FriendRequestApiRequest(
    val friendIdString: String
)

@Serializable
data class RespondFriendRequestApiRequest(
    val requestId: Int,
    val action: String
)

@Serializable
data class FriendNotificationDto(
    val id: Int,
    val type: String,
    val message: String,
    val isRead: Boolean,
    val createdAt: String,
    val senderNickname: String? = null,
    val senderTag: String? = null,
    val friendRequestId: Int? = null
)

@Serializable
data class FriendNotificationsResponse(
    val success: Boolean,
    val notifications: List<FriendNotificationDto>? = null,
    val error: String? = null
)


interface TabsApi {

    @POST("api/auth/register")
    suspend fun register(@Body request: AuthRequest): Response<AuthResponse>

    @POST("api/auth/login")
    suspend fun login(@Body request: AuthRequest): Response<AuthResponse>

    @POST("api/auth/google")
    suspend fun googleLogin(@Body request: GoogleAuthRequest): Response<AuthResponse>

    @POST("api/auth/forgot-password")
    suspend fun forgotPassword(@Body request: ForgotPasswordRequest): Response<GenericResponse>

    @POST("api/auth/update-password")
    suspend fun updatePassword(@Body request: UpdatePasswordRequest): Response<GenericResponse>

    @retrofit2.http.GET("api/auth/check-nickname")
    suspend fun checkNickname(@retrofit2.http.Query("name") name: String): Response<NicknameCheckResponse>

    @POST("api/auth/update-nickname")
    suspend fun updateNickname(@Body request: UpdateNicknameRequest): Response<UpdateNicknameResponse>

    @retrofit2.http.DELETE("api/auth/delete-account")
    suspend fun deleteAccount(): Response<GenericResponse>

    @POST("api/friends/request")
    suspend fun sendFriendRequest(@Body request: FriendRequestApiRequest): Response<GenericResponse>

    @GET("api/friends/list")
    suspend fun getFriendsList(): Response<FriendsListResponse>

    @retrofit2.http.GET("api/friends/data/{friendId}")
    suspend fun getFriendDetail(@retrofit2.http.Path("friendId") friendId: String): Response<FriendDetailResponse>

    @POST("api/friends/respond")
    suspend fun respondFriendRequest(@Body request: RespondFriendRequestApiRequest): Response<GenericResponse>

    @GET("api/friends/notifications")
    suspend fun getFriendNotifications(): Response<FriendNotificationsResponse>

    @POST("api/friends/notifications/read")
    suspend fun markFriendNotificationsRead(): Response<GenericResponse>

    @POST("api/ai/suggestions")
    suspend fun getSuggestions(@Body request: SuggestionsRequest): Response<AiResponse<List<String>>>

    @POST("api/ai/generate-categories")
    suspend fun generateCategories(@Body request: GenerateCategoriesRequest): Response<AiResponse<List<String>>>

    @POST("api/ai/smart-category-suggestion")
    suspend fun getSmartCategorySuggestion(@Body request: SmartCategorySuggestionRequest): Response<AiResponse<List<SmartCategorySuggestion>>>

    @POST("api/ai/validate-category")
    suspend fun validateCategory(@Body request: CategoryValidationRequest): Response<AiResponse<CategoryValidationResponse>>

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

    @POST("api/ai/body-load")
    suspend fun getBodyLoad(@Body request: AiRequest): Response<AiResponse<BodyLoadResponse>>

    @POST("api/ai/body-load-enriched")
    suspend fun getBodyLoadEnriched(@Body request: BodyLoadEnrichedRequest): Response<AiResponse<BodyLoadResponse>>

    @POST("api/ai/classify-and-clean")
    suspend fun classifyAndClean(@Body request: ClassifyAndCleanRequest): Response<AiResponse<ClassifyAndCleanResponse>>

    @POST("api/ai/body-impacts")
    suspend fun evaluateBodyImpacts(@Body request: AiBodyImpactRequest): Response<AiResponse<AiBodyImpactResponse>>

    @POST("api/ai/classify-coach-note")
    suspend fun classifyCoachNote(@Body request: ClassifyAndCleanRequest): Response<AiResponse<ClassifyCoachNoteResponse>>

    @POST("api/ai/coach")
    suspend fun getCoachReply(@Body request: CoachRequest): Response<AiResponse<String>>

    @POST("api/ai/coach/title")
    suspend fun getCoachTitle(@Body request: TitleRequest): Response<TitleResponse>

    @POST("api/ai/focus-suggestions")
    suspend fun getFocusSuggestions(@Body request: FocusSuggestionsRequest): Response<AiResponse<List<FocusSuggestion>>>

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

    @retrofit2.http.DELETE("api/sync/insights/{id}")
    suspend fun deleteInsight(@retrofit2.http.Path("id") id: String): Response<SyncResponse>

    @POST("api/sync/documents")
    suspend fun syncDocuments(@Body request: SyncDocumentsRequest): Response<SyncResponse>

    @POST("api/sync/coach_sessions")
    suspend fun syncCoachSessions(@Body request: SyncCoachSessionsRequest): Response<SyncResponse>

    @POST("api/sync/coach_messages")
    suspend fun syncCoachMessages(@Body request: SyncCoachMessagesRequest): Response<SyncResponse>

    @retrofit2.http.GET("api/sync/documents/{id}")
    suspend fun getDocumentData(@retrofit2.http.Path("id") id: String): Response<AiResponse<String>>

    @retrofit2.http.DELETE("api/sync/entries/{localId}")
    suspend fun deleteEntry(@retrofit2.http.Path("localId") localId: Long): Response<GenericResponse>

    @retrofit2.http.DELETE("api/sync/categories/{localId}")
    suspend fun deleteRemoteCategory(@retrofit2.http.Path("localId") localId: Int): Response<GenericResponse>

    @retrofit2.http.DELETE("api/sync/documents/{id}")
    suspend fun deleteDocument(@retrofit2.http.Path("id") id: String): Response<GenericResponse>

    @retrofit2.http.DELETE("api/sync/coach_sessions/{id}")
    suspend fun deleteCoachSession(@retrofit2.http.Path("id") id: String): Response<GenericResponse>

    // ── BILLING ──────────────────────────────────────────
    @POST("api/billing/verify")
    suspend fun verifyPurchase(@Body request: BillingVerificationRequest): Response<BillingVerificationResponse>

    @POST("api/billing/sync-subscriptions")
    suspend fun syncSubscriptions(@Body request: SubscriptionSyncRequest): Response<SubscriptionSyncResponse>

    // ── HABITS ───────────────────────────────────────────
    @retrofit2.http.GET("api/habits")
    suspend fun getHabits(): Response<HabitListResponse>

    @POST("api/habits")
    suspend fun createHabit(@Body request: CreateHabitRequest): Response<CreateHabitResponse>

    @retrofit2.http.DELETE("api/habits/{id}")
    suspend fun deleteHabit(@retrofit2.http.Path("id") id: String): Response<GenericResponse>

    @POST("api/habits/log")
    suspend fun logHabit(@Body request: LogHabitRequest): Response<GenericResponse>

    @POST("api/habits/clear")
    suspend fun clearHabitData(): Response<GenericResponse>
}
