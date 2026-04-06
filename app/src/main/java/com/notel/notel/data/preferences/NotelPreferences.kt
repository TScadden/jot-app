package com.notel.notel.data.preferences

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.first
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import javax.inject.Inject
import javax.inject.Singleton

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "notel_prefs")

@Singleton
class NotelPreferences @Inject constructor(
    @ApplicationContext private val context: Context
) {
    companion object {
        val AUTH_TOKEN = stringPreferencesKey("auth_token")
        val ONBOARDING_COMPLETE = booleanPreferencesKey("onboarding_complete")
        val LOGGED_IN = booleanPreferencesKey("logged_in")
        val USER_CONTEXT = stringPreferencesKey("user_context")
        val KNOWLEDGE_BASE = stringPreferencesKey("knowledge_base")
        val PROCESSED_FILES = stringPreferencesKey("processed_files")
        val PROFESSIONAL_UPDATES = stringPreferencesKey("professional_updates")
        val LOGGED_DAYS = stringPreferencesKey("logged_days")
        val AI_INSIGHTS = stringPreferencesKey("ai_insights")
        val FITBIT_TOKEN = stringPreferencesKey("fitbit_token")
        val FITBIT_REFRESH_TOKEN = stringPreferencesKey("fitbit_refresh_token")
        
        val API_SPENDING_LIMIT = floatPreferencesKey("api_spending_limit")
        val CURRENT_MONTH_COST = floatPreferencesKey("current_month_cost")
        val CURRENT_COST_MONTH = stringPreferencesKey("current_cost_month")

        val HISTORICAL_HEART_RATE = stringPreferencesKey("historical_heart_rate")
        val HISTORICAL_SLEEP = stringPreferencesKey("historical_sleep")
        val HISTORICAL_CALORIES = stringPreferencesKey("historical_calories")
        val HISTORICAL_HR_SPIKES = stringPreferencesKey("historical_hr_spikes")

        val USER_AGE = intPreferencesKey("user_age")
        val USER_HEIGHT = floatPreferencesKey("user_height")
        val USER_WEIGHT = floatPreferencesKey("user_weight")
        val USER_GENDER = stringPreferencesKey("user_gender")
        val USER_BALANCE = floatPreferencesKey("user_balance")
        val SHOW_FREE_CREDIT_POPUP = booleanPreferencesKey("show_free_credit_popup")
        val IS_UNLIMITED = booleanPreferencesKey("is_unlimited")
        val AUTO_AI_SUGGESTIONS = booleanPreferencesKey("auto_ai_suggestions")

        val EVENT_COUNTERS = stringPreferencesKey("event_counters")
        val COUNTER_HISTORY = stringPreferencesKey("counter_history")
        val SETTINGS_TUTORIAL_SEEN = booleanPreferencesKey("settings_tutorial_seen")
        val REDDIT_SUBREDDITS = stringPreferencesKey("reddit_subreddits")
        val BODY_LOAD_REMINDERS_ENABLED = booleanPreferencesKey("body_load_reminders_enabled")
        val DAILY_CUP_UPDATES_ENABLED = booleanPreferencesKey("daily_cup_updates_enabled")
        val HR_SPIKE_ALERTS_ENABLED = booleanPreferencesKey("hr_spike_alerts_enabled")
        val SPIKE_THRESHOLD = intPreferencesKey("spike_threshold")
        val HR_DELTA_ENABLED = booleanPreferencesKey("hr_delta_enabled")
        val SPIKE_DELTA_THRESHOLD = intPreferencesKey("spike_delta_threshold")
        val HR_LAST_POKED_BPM = intPreferencesKey("hr_last_poked_bpm")
        val HABIT_REMINDER_ENABLED = booleanPreferencesKey("habit_reminder_enabled")
        val HR_LAST_ALERT_TIME = longPreferencesKey("hr_last_alert_time")
        val HR_LAST_SAMPLE_TIME = longPreferencesKey("hr_last_sample_time")
        val HABIT_REMINDER_USER_DISABLED = booleanPreferencesKey("habit_reminder_user_disabled")
        val USER_CONTEXT_LAST_UPDATE = longPreferencesKey("user_context_last_update")
    }

    val authToken: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[AUTH_TOKEN] ?: ""
    }

    val professionalUpdates: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[PROFESSIONAL_UPDATES] ?: ""
    }

    val eventCounters: Flow<String> = context.dataStore.data.map { it[EVENT_COUNTERS] ?: "[]" }
    val counterHistory: Flow<String> = context.dataStore.data.map { it[COUNTER_HISTORY] ?: "[]" }
    val settingsTutorialSeen: Flow<Boolean> = context.dataStore.data.map { it[SETTINGS_TUTORIAL_SEEN] ?: false }
    val bodyLoadRemindersEnabled: Flow<Boolean> = context.dataStore.data.map { it[BODY_LOAD_REMINDERS_ENABLED] ?: true }
    val dailyCupUpdatesEnabled: Flow<Boolean> = context.dataStore.data.map { it[DAILY_CUP_UPDATES_ENABLED] ?: true }
    val hrSpikeAlertsEnabled: Flow<Boolean> = context.dataStore.data.map { it[HR_SPIKE_ALERTS_ENABLED] ?: false }
    val spikeThreshold: Flow<Int> = context.dataStore.data.map { it[SPIKE_THRESHOLD] ?: 120 }
    val hrDeltaEnabled: Flow<Boolean> = context.dataStore.data.map { it[HR_DELTA_ENABLED] ?: false }
    val spikeDeltaThreshold: Flow<Int> = context.dataStore.data.map { it[SPIKE_DELTA_THRESHOLD] ?: 30 }
    val hrLastPokedBpm: Flow<Int> = context.dataStore.data.map { it[HR_LAST_POKED_BPM] ?: 0 }
    val habitReminderEnabled: Flow<Boolean> = context.dataStore.data.map { it[HABIT_REMINDER_ENABLED] ?: false }
    val redditSubreddits: Flow<String> = context.dataStore.data.map { it[REDDIT_SUBREDDITS] ?: "[]" }
    val hrLastAlertTime: Flow<Long> = context.dataStore.data.map { it[HR_LAST_ALERT_TIME] ?: 0L }
    val hrLastSampleTime: Flow<Long> = context.dataStore.data.map { it[HR_LAST_SAMPLE_TIME] ?: 0L }
    val habitReminderUserDisabled: Flow<Boolean> = context.dataStore.data.map { it[HABIT_REMINDER_USER_DISABLED] ?: false }
    val userContextLastUpdate: Flow<Long> = context.dataStore.data.map { it[USER_CONTEXT_LAST_UPDATE] ?: 0L }

    val onboardingComplete: Flow<Boolean> = context.dataStore.data.map { prefs ->
        prefs[ONBOARDING_COMPLETE] ?: false
    }

    val autoAiSuggestions: Flow<Boolean> = context.dataStore.data.map { prefs ->
        prefs[AUTO_AI_SUGGESTIONS] ?: true
    }

    val loggedIn: Flow<Boolean> = context.dataStore.data.map { prefs ->
        prefs[LOGGED_IN] ?: false
    }

    val userContext: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[USER_CONTEXT] ?: ""
    }

    val knowledgeBase: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[KNOWLEDGE_BASE] ?: ""
    }

    val processedFiles: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[PROCESSED_FILES] ?: ""
    }

    val loggedDays: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[LOGGED_DAYS] ?: ""
    }

    val aiInsights: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[AI_INSIGHTS] ?: "[]"
    }

    val fitbitToken: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[FITBIT_TOKEN] ?: ""
    }

    val fitbitRefreshToken: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[FITBIT_REFRESH_TOKEN] ?: ""
    }

    val apiSpendingLimit: Flow<Float> = context.dataStore.data.map { prefs ->
        prefs[API_SPENDING_LIMIT] ?: 0f
    }

    val currentMonthCost: Flow<Float> = context.dataStore.data.map { prefs ->
        prefs[CURRENT_MONTH_COST] ?: 0f
    }

    val currentCostMonth: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[CURRENT_COST_MONTH] ?: ""
    }

    val historicalHeartRate: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[HISTORICAL_HEART_RATE] ?: ""
    }

    val historicalSleep: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[HISTORICAL_SLEEP] ?: ""
    }

    val historicalCalories: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[HISTORICAL_CALORIES] ?: ""
    }

    val historicalHrSpikes: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[HISTORICAL_HR_SPIKES] ?: ""
    }

    val userAge: Flow<Int> = context.dataStore.data.map { prefs ->
        prefs[USER_AGE] ?: 0
    }

    val userHeight: Flow<Float> = context.dataStore.data.map { prefs ->
        prefs[USER_HEIGHT] ?: 0f
    }

    val userWeight: Flow<Float> = context.dataStore.data.map { prefs ->
        prefs[USER_WEIGHT] ?: 0f
    }

    val userGender: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[USER_GENDER] ?: ""
    }

    val userBalance: Flow<Float> = context.dataStore.data.map { prefs ->
        prefs[USER_BALANCE] ?: 0f
    }

    val showFreeCreditPopup: Flow<Boolean> = context.dataStore.data.map { prefs ->
        prefs[SHOW_FREE_CREDIT_POPUP] ?: false
    }

    val isUnlimited: Flow<Boolean> = context.dataStore.data.map { prefs ->
        prefs[IS_UNLIMITED] ?: false
    }


    suspend fun setAuthToken(token: String) {
        context.dataStore.edit { it[AUTH_TOKEN] = token }
    }

    suspend fun setOnboardingComplete(complete: Boolean) {
        context.dataStore.edit { prefs -> prefs[ONBOARDING_COMPLETE] = complete }
    }

    suspend fun setUserContextLastUpdate(timestamp: Long) {
        context.dataStore.edit { prefs -> prefs[USER_CONTEXT_LAST_UPDATE] = timestamp }
    }

    suspend fun setLoggedIn(loggedIn: Boolean) {
        context.dataStore.edit { it[LOGGED_IN] = loggedIn }
    }

    suspend fun setUserContext(text: String) {
        context.dataStore.edit { it[USER_CONTEXT] = text }
    }

    suspend fun setKnowledgeBase(text: String) {
        context.dataStore.edit { it[KNOWLEDGE_BASE] = text }
    }

    suspend fun setProfessionalUpdates(text: String) {
        context.dataStore.edit { it[PROFESSIONAL_UPDATES] = text }
    }

    suspend fun setProcessedFiles(json: String) {
        context.dataStore.edit { it[PROCESSED_FILES] = json }
    }

    suspend fun setLoggedDays(jsonArray: String) {
        context.dataStore.edit { it[LOGGED_DAYS] = jsonArray }
    }

    suspend fun setAiInsights(jsonArray: String) {
        context.dataStore.edit { it[AI_INSIGHTS] = jsonArray }
    }

    suspend fun setFitbitToken(token: String) {
        context.dataStore.edit { it[FITBIT_TOKEN] = token }
    }

    suspend fun setFitbitRefreshToken(token: String) {
        context.dataStore.edit { it[FITBIT_REFRESH_TOKEN] = token }
    }

    suspend fun setApiSpendingLimit(limit: Float) {
        context.dataStore.edit { it[API_SPENDING_LIMIT] = limit }
    }

    suspend fun setCurrentMonthCost(cost: Float) {
        context.dataStore.edit { it[CURRENT_MONTH_COST] = cost }
    }

    suspend fun setCurrentCostMonth(month: String) {
        context.dataStore.edit { it[CURRENT_COST_MONTH] = month }
    }

    suspend fun setHistoricalHeartRate(json: String) {
        context.dataStore.edit { it[HISTORICAL_HEART_RATE] = json }
    }

    suspend fun setHistoricalSleep(json: String) {
        context.dataStore.edit { it[HISTORICAL_SLEEP] = json }
    }

    suspend fun setHistoricalCalories(json: String) {
        context.dataStore.edit { it[HISTORICAL_CALORIES] = json }
    }

    suspend fun setHistoricalHrSpikes(json: String) {
        context.dataStore.edit { it[HISTORICAL_HR_SPIKES] = json }
    }

    suspend fun setUserAge(age: Int) {
        context.dataStore.edit { it[USER_AGE] = age }
    }

    suspend fun setUserHeight(height: Float) {
        context.dataStore.edit { it[USER_HEIGHT] = height }
    }

    suspend fun setUserWeight(weight: Float) {
        context.dataStore.edit { it[USER_WEIGHT] = weight }
    }

    suspend fun setUserGender(gender: String) {
        context.dataStore.edit { it[USER_GENDER] = gender }
    }

    suspend fun setUserBalance(balance: Float) {
        context.dataStore.edit { it[USER_BALANCE] = balance }
    }

    suspend fun setShowFreeCreditPopup(show: Boolean) {
        context.dataStore.edit { it[SHOW_FREE_CREDIT_POPUP] = show }
    }

    suspend fun setIsUnlimited(unlimited: Boolean) {
        context.dataStore.edit { it[IS_UNLIMITED] = unlimited }
    }
    suspend fun setAutoAiSuggestions(enabled: Boolean) {
        context.dataStore.edit { it[AUTO_AI_SUGGESTIONS] = enabled }
    }

    suspend fun deductBalance(amount: Float) {
        val prefs = context.dataStore.data.first()
        if (prefs[IS_UNLIMITED] == true) return
        
        context.dataStore.edit { p: MutablePreferences ->
            val current = p[USER_BALANCE] ?: 0f
            p[USER_BALANCE] = (current - amount).coerceAtLeast(0f)
        }
    }

    suspend fun setUserProfileStats(age: Int, height: Float, weight: Float, gender: String) {
        context.dataStore.edit {
            it[USER_AGE] = age
            it[USER_HEIGHT] = height
            it[USER_WEIGHT] = weight
            it[USER_GENDER] = gender
        }
    }

    suspend fun clearCredentials() {
        context.dataStore.edit { it.clear() }
    }

    suspend fun setEventCounters(jsonArray: String) {
        context.dataStore.edit {
            it[EVENT_COUNTERS] = jsonArray
        }
    }

    suspend fun setCounterHistory(jsonArray: String) {
        context.dataStore.edit { it[COUNTER_HISTORY] = jsonArray }
    }

    suspend fun setRedditSubreddits(jsonArray: String) {
        context.dataStore.edit { it[REDDIT_SUBREDDITS] = jsonArray }
    }

    suspend fun setSettingsTutorialSeen(seen: Boolean) {
        context.dataStore.edit { it[SETTINGS_TUTORIAL_SEEN] = seen }
    }

    suspend fun setBodyLoadRemindersEnabled(enabled: Boolean) {
        context.dataStore.edit { it[BODY_LOAD_REMINDERS_ENABLED] = enabled }
    }

    suspend fun setDailyCupUpdatesEnabled(enabled: Boolean) {
        context.dataStore.edit { it[DAILY_CUP_UPDATES_ENABLED] = enabled }
    }

    suspend fun setHrSpikeAlertsEnabled(enabled: Boolean) {
        context.dataStore.edit { it[HR_SPIKE_ALERTS_ENABLED] = enabled }
    }

    suspend fun setSpikeThreshold(threshold: Int) {
        context.dataStore.edit { it[SPIKE_THRESHOLD] = threshold }
    }

    suspend fun setHrDeltaEnabled(enabled: Boolean) {
        context.dataStore.edit { it[HR_DELTA_ENABLED] = enabled }
    }

    suspend fun setSpikeDeltaThreshold(threshold: Int) {
        context.dataStore.edit { it[SPIKE_DELTA_THRESHOLD] = threshold }
    }

    suspend fun setHrLastPokedBpm(bpm: Int) {
        context.dataStore.edit { it[HR_LAST_POKED_BPM] = bpm }
    }

    suspend fun setHabitReminderEnabled(enabled: Boolean) {
        context.dataStore.edit {
            it[HABIT_REMINDER_ENABLED] = enabled
            // If the user manually turns it off, we mark it as explicitly disabled
            if (!enabled) {
                it[HABIT_REMINDER_USER_DISABLED] = true
            } else {
                it[HABIT_REMINDER_USER_DISABLED] = false
            }
        }
    }

    suspend fun autoEnableHabitReminders() {
        context.dataStore.edit {
            val userDisabled = it[HABIT_REMINDER_USER_DISABLED] ?: false
            if (!userDisabled) {
                it[HABIT_REMINDER_ENABLED] = true
            }
        }
    }

    suspend fun setHrLastAlertTime(time: Long) {
        context.dataStore.edit { it[HR_LAST_ALERT_TIME] = time }
    }

    suspend fun setHrLastSampleTime(time: Long) {
        context.dataStore.edit { it[HR_LAST_SAMPLE_TIME] = time }
    }
}
