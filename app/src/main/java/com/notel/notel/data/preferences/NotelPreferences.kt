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
import androidx.datastore.preferences.core.doublePreferencesKey
import javax.inject.Inject
import javax.inject.Singleton
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.util.Base64

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
        val TODAY_AWAKE_AVG_HR = intPreferencesKey("today_awake_avg_hr")

        val USER_AGE = intPreferencesKey("user_age")
        val USER_HEIGHT = floatPreferencesKey("user_height")
        val USER_WEIGHT = floatPreferencesKey("user_weight")
        val USER_GENDER = stringPreferencesKey("user_gender")
        val IS_UNLIMITED = booleanPreferencesKey("is_unlimited")
        val AUTO_AI_SUGGESTIONS = booleanPreferencesKey("auto_ai_suggestions")

        val EVENT_COUNTERS = stringPreferencesKey("event_counters")
        val COUNTER_HISTORY = stringPreferencesKey("counter_history")
        val SETTINGS_TUTORIAL_SEEN = booleanPreferencesKey("settings_tutorial_seen")
        val REDDIT_SUBREDDITS = stringPreferencesKey("reddit_subreddits")
        val REDDIT_SUMMARIES = stringPreferencesKey("reddit_summaries")
        val BODY_LOAD_REMINDERS_ENABLED = booleanPreferencesKey("body_load_reminders_enabled")
        val DAILY_CUP_UPDATES_ENABLED = booleanPreferencesKey("daily_cup_updates_enabled")
        val HR_SPIKE_ALERTS_ENABLED = booleanPreferencesKey("hr_spike_alerts_enabled")
        val SPIKE_THRESHOLD = intPreferencesKey("spike_threshold")
        val HR_DELTA_ENABLED = booleanPreferencesKey("hr_delta_enabled")
        val SPIKE_DELTA_THRESHOLD = intPreferencesKey("spike_delta_threshold")
        val HR_LAST_POKED_BPM = intPreferencesKey("hr_last_poked_bpm")
        val HABIT_REMINDER_ENABLED = booleanPreferencesKey("habit_reminder_enabled")
        val PROJECT_REMINDER_ENABLED = booleanPreferencesKey("project_reminder_enabled")
        val HR_LAST_ALERT_TIME = longPreferencesKey("hr_last_alert_time")
        val HR_LAST_SAMPLE_TIME = longPreferencesKey("hr_last_sample_time")
        val HABIT_REMINDER_USER_DISABLED = booleanPreferencesKey("habit_reminder_user_disabled")
        val USER_CONTEXT_LAST_UPDATE = longPreferencesKey("user_context_last_update")
        val LAST_BODY_LOAD_REFRESH = longPreferencesKey("last_body_load_refresh")
        val LAST_BODY_LOAD_SCORE = intPreferencesKey("last_body_load_score")
        val LAST_BODY_LOAD_FACTORS = stringPreferencesKey("last_body_load_factors")
        val LAST_BODY_LOAD_ADVICE = stringPreferencesKey("last_body_load_advice")
        
        val CURRENT_STREAK = intPreferencesKey("current_streak")
        val BEST_STREAK = intPreferencesKey("best_streak")
        val LAST_OPEN_DATE = stringPreferencesKey("last_open_date")
        val CUP_THEORY_SEEN = booleanPreferencesKey("cup_theory_seen")
        val LAST_DYNAMIC_NOTIFICATION_DATE = stringPreferencesKey("last_dynamic_notification_date")
        val LAST_KNOWN_STATS = stringPreferencesKey("last_known_stats")
        val LAST_KNOWN_LAT = doublePreferencesKey("last_known_lat")
        val LAST_KNOWN_LON = doublePreferencesKey("last_known_lon")
        val LAST_KNOWN_CITY = stringPreferencesKey("last_known_city")
        val HIGHEST_CUP_DAILY = intPreferencesKey("highest_cup_daily")
        val USER_CONTEXT_HIDDEN = booleanPreferencesKey("user_context_hidden")
        val HAS_HISTORICAL_BODY_LOAD = booleanPreferencesKey("has_historical_body_load")
        val LAST_SYNC_TIME = longPreferencesKey("last_sync_time")
        val HISTORICAL_DAILY_STATS = stringPreferencesKey("historical_daily_stats")
        val TIPS_AND_TRICKS_TOPICS = stringPreferencesKey("tips_and_tricks_topics")
        val TIPS_AND_TRICKS_ANSWERS = stringPreferencesKey("tips_and_tricks_answers")
        val FOOD_CHECKER_HISTORY = stringPreferencesKey("food_checker_history")
        val FOOD_CHECKER_LAST_QUERY = stringPreferencesKey("food_checker_last_query")
        val USER_NICKNAME = stringPreferencesKey("user_nickname")
        val USER_TAG = stringPreferencesKey("user_tag")
        val WEEKLY_SCORE = intPreferencesKey("weekly_score")
        val SHARE_DATA_WITH_FRIENDS = booleanPreferencesKey("share_data_with_friends")
        val TODAY_SLEEP_MINS = intPreferencesKey("today_sleep_mins")
        val TODAY_AVG_HR = intPreferencesKey("today_avg_hr_shared")
        val TODAY_SCORE = intPreferencesKey("today_score")
        val TODAY_SPIKES = intPreferencesKey("today_spikes")
        val TODAY_SLEEP_DEBT = intPreferencesKey("today_sleep_debt")
        val FOCUS_STATE = stringPreferencesKey("focus_state")
        val HAS_VISIBLE_BAND_ASKED = booleanPreferencesKey("has_visible_band_asked")
        val LAST_CONNECTED_DEVICE_ADDRESS = stringPreferencesKey("last_connected_device_address")
        val LAST_CONNECTED_DEVICE_NAME = stringPreferencesKey("last_connected_device_name")
        val HEART_RATE_HISTORY = stringPreferencesKey("heart_rate_history")
        val GOOGLE_CALENDAR_CONNECTED = booleanPreferencesKey("google_calendar_connected")
        val GOOGLE_CALENDAR_EMAIL = stringPreferencesKey("google_calendar_email")
    }

    val googleCalendarConnected: Flow<Boolean> = context.dataStore.data.map { it[GOOGLE_CALENDAR_CONNECTED] ?: false }
    suspend fun setGoogleCalendarConnected(connected: Boolean) {
        context.dataStore.edit { it[GOOGLE_CALENDAR_CONNECTED] = connected }
    }

    val googleCalendarEmail: Flow<String> = context.dataStore.data.map { it[GOOGLE_CALENDAR_EMAIL] ?: "" }
    suspend fun setGoogleCalendarEmail(email: String) {
        context.dataStore.edit { it[GOOGLE_CALENDAR_EMAIL] = email }
    }


    val hasVisibleBandAsked: Flow<Boolean> = context.dataStore.data.map { it[HAS_VISIBLE_BAND_ASKED] ?: false }
    suspend fun setHasVisibleBandAsked(asked: Boolean) {
        context.dataStore.edit { it[HAS_VISIBLE_BAND_ASKED] = asked }
    }

    val lastConnectedDeviceAddress: Flow<String> = context.dataStore.data.map { it[LAST_CONNECTED_DEVICE_ADDRESS] ?: "" }
    suspend fun setLastConnectedDeviceAddress(address: String) {
        context.dataStore.edit { it[LAST_CONNECTED_DEVICE_ADDRESS] = address }
    }

    val lastConnectedDeviceName: Flow<String> = context.dataStore.data.map { it[LAST_CONNECTED_DEVICE_NAME] ?: "" }
    suspend fun setLastConnectedDeviceName(name: String) {
        context.dataStore.edit { it[LAST_CONNECTED_DEVICE_NAME] = name }
    }

    val heartRateHistory: Flow<String> = context.dataStore.data.map { it[HEART_RATE_HISTORY] ?: "[]" }
    suspend fun setHeartRateHistory(historyJson: String) {
        context.dataStore.edit { it[HEART_RATE_HISTORY] = historyJson }
    }

    val historicalDailyStats: Flow<String> = context.dataStore.data.map { it[HISTORICAL_DAILY_STATS] ?: "{}" }
    suspend fun setHistoricalDailyStats(json: String) { context.dataStore.edit { it[HISTORICAL_DAILY_STATS] = json } }

    val hasHistoricalBodyLoad: Flow<Boolean> = context.dataStore.data.map { it[HAS_HISTORICAL_BODY_LOAD] ?: false }
    suspend fun setHasHistoricalBodyLoad(v: Boolean) { context.dataStore.edit { it[HAS_HISTORICAL_BODY_LOAD] = v } }

    val tipsAndTricksTopics: Flow<String> = context.dataStore.data.map { it[TIPS_AND_TRICKS_TOPICS] ?: "" }
    val tipsAndTricksAnswers: Flow<String> = context.dataStore.data.map { it[TIPS_AND_TRICKS_ANSWERS] ?: "" }
    val foodCheckerHistory: Flow<String> = context.dataStore.data.map { it[FOOD_CHECKER_HISTORY] ?: "{}" }
    val foodCheckerLastQuery: Flow<String> = context.dataStore.data.map { it[FOOD_CHECKER_LAST_QUERY] ?: "[]" }

    val authToken: Flow<String> = context.dataStore.data.map { prefs ->
        val encrypted = prefs[AUTH_TOKEN] ?: ""
        if (encrypted.isEmpty()) return@map ""
        if (!NotelCrypto.isLikelyCiphertext(encrypted)) {
            encrypted
        } else {
            val decrypted = NotelCrypto.decrypt(encrypted)
            if (decrypted.isNotEmpty()) decrypted else ""
        }
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
    val projectReminderEnabled: Flow<Boolean> = context.dataStore.data.map { it[PROJECT_REMINDER_ENABLED] ?: true }
    val redditSubreddits: Flow<String> = context.dataStore.data.map { it[REDDIT_SUBREDDITS] ?: "[]" }
    val redditSummaries: Flow<String> = context.dataStore.data.map { it[REDDIT_SUMMARIES] ?: "" }
    val hrLastAlertTime: Flow<Long> = context.dataStore.data.map { it[HR_LAST_ALERT_TIME] ?: 0L }
    val hrLastSampleTime: Flow<Long> = context.dataStore.data.map { it[HR_LAST_SAMPLE_TIME] ?: 0L }
    val habitReminderUserDisabled: Flow<Boolean> = context.dataStore.data.map { it[HABIT_REMINDER_USER_DISABLED] ?: false }
    val userContextLastUpdate: Flow<Long> = context.dataStore.data.map { it[USER_CONTEXT_LAST_UPDATE] ?: 0L }
    val lastBodyLoadRefresh: Flow<Long> = context.dataStore.data.map { it[LAST_BODY_LOAD_REFRESH] ?: 0L }
    val lastSyncTime: Flow<Long> = context.dataStore.data.map { it[LAST_SYNC_TIME] ?: 0L }
    val lastBodyLoadScore: Flow<Int> = context.dataStore.data.map { it[LAST_BODY_LOAD_SCORE] ?: 0 }
    val lastBodyLoadFactors: Flow<String> = context.dataStore.data.map { it[LAST_BODY_LOAD_FACTORS] ?: "" }
    val lastBodyLoadAdvice: Flow<String?> = context.dataStore.data.map { it[LAST_BODY_LOAD_ADVICE] }
    
    val currentStreak: Flow<Int> = context.dataStore.data.map { it[CURRENT_STREAK] ?: 0 }
    val bestStreak: Flow<Int> = context.dataStore.data.map { it[BEST_STREAK] ?: 0 }
    val lastOpenDate: Flow<String> = context.dataStore.data.map { it[LAST_OPEN_DATE] ?: "" }
    val userNickname: Flow<String> = context.dataStore.data.map { it[USER_NICKNAME] ?: "" }
    val userTag: Flow<String> = context.dataStore.data.map { it[USER_TAG] ?: "" }
    val weeklyScore: Flow<Int> = context.dataStore.data.map { it[WEEKLY_SCORE] ?: 0 }
    val shareDataWithFriends: Flow<Boolean> = context.dataStore.data.map { it[SHARE_DATA_WITH_FRIENDS] ?: true }
    val todaySleepMins: Flow<Int> = context.dataStore.data.map { it[TODAY_SLEEP_MINS] ?: 0 }
    val todayAvgHrShared: Flow<Int> = context.dataStore.data.map { it[TODAY_AVG_HR] ?: 0 }
    val todayScore: Flow<Int> = context.dataStore.data.map { it[TODAY_SCORE] ?: 0 }
    val todaySpikes: Flow<Int> = context.dataStore.data.map { it[TODAY_SPIKES] ?: 0 }
    val todaySleepDebt: Flow<Int> = context.dataStore.data.map { it[TODAY_SLEEP_DEBT] ?: 0 }
    val focusState: Flow<String> = context.dataStore.data.map { it[FOCUS_STATE] ?: "{}" }
    
    suspend fun setWeeklyScore(score: Int) {
        context.dataStore.edit { it[WEEKLY_SCORE] = score }
    }
    
    val cupTheorySeen: Flow<Boolean> = context.dataStore.data.map { it[CUP_THEORY_SEEN] ?: false }
    val lastDynamicNotificationDate: Flow<String> = context.dataStore.data.map { it[LAST_DYNAMIC_NOTIFICATION_DATE] ?: "" }
    val lastKnownStats: Flow<String> = context.dataStore.data.map { it[LAST_KNOWN_STATS] ?: "{}" }
    val lastKnownLat: Flow<Double> = context.dataStore.data.map { it[LAST_KNOWN_LAT] ?: 0.0 }
    val lastKnownLon: Flow<Double> = context.dataStore.data.map { it[LAST_KNOWN_LON] ?: 0.0 }
    val lastKnownCity: Flow<String?> = context.dataStore.data.map { it[LAST_KNOWN_CITY] }

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
        val encrypted = prefs[FITBIT_TOKEN] ?: ""
        if (encrypted.isEmpty()) return@map ""
        if (!NotelCrypto.isLikelyCiphertext(encrypted)) {
            encrypted
        } else {
            val decrypted = NotelCrypto.decrypt(encrypted)
            if (decrypted.isNotEmpty()) decrypted else ""
        }
    }

    val fitbitRefreshToken: Flow<String> = context.dataStore.data.map { prefs ->
        val encrypted = prefs[FITBIT_REFRESH_TOKEN] ?: ""
        if (encrypted.isEmpty()) return@map ""
        if (!NotelCrypto.isLikelyCiphertext(encrypted)) {
            encrypted
        } else {
            val decrypted = NotelCrypto.decrypt(encrypted)
            if (decrypted.isNotEmpty()) decrypted else ""
        }
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
    val todayAwakeAvgHr: Flow<Int> = context.dataStore.data.map { prefs ->
        prefs[TODAY_AWAKE_AVG_HR] ?: 0
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

    val isUnlimited: Flow<Boolean> = context.dataStore.data.map { prefs ->
        prefs[IS_UNLIMITED] ?: false
    }

    val userContextHidden: Flow<Boolean> = context.dataStore.data.map { prefs ->
        prefs[USER_CONTEXT_HIDDEN] ?: true
    }

    suspend fun setAuthToken(token: String) {
        val encrypted = NotelCrypto.encrypt(token)
        context.dataStore.edit { it[AUTH_TOKEN] = encrypted }
    }

    suspend fun setOnboardingComplete(complete: Boolean) {
        context.dataStore.edit { prefs -> prefs[ONBOARDING_COMPLETE] = complete }
    }

    suspend fun setUserContextLastUpdate(timestamp: Long) {
        context.dataStore.edit { prefs -> prefs[USER_CONTEXT_LAST_UPDATE] = timestamp }
    }
    suspend fun setLastSyncTime(timestamp: Long) {
        context.dataStore.edit { prefs -> prefs[LAST_SYNC_TIME] = timestamp }
    }
    suspend fun setLastBodyLoadRefresh(timestamp: Long) {
        context.dataStore.edit { prefs -> prefs[LAST_BODY_LOAD_REFRESH] = timestamp }
    }
    suspend fun setLastBodyLoadData(score: Int, factors: String, advice: String?) {
        context.dataStore.edit { prefs ->
            prefs[LAST_BODY_LOAD_SCORE] = score
            prefs[LAST_BODY_LOAD_FACTORS] = factors
            if (advice != null) prefs[LAST_BODY_LOAD_ADVICE] = advice else prefs.remove(LAST_BODY_LOAD_ADVICE)
        }
    }

    suspend fun updateStreak() {
        val today = java.time.LocalDate.now()
        context.dataStore.edit { prefs ->
            val lastOpenStr = prefs[LAST_OPEN_DATE] ?: ""
            var current = prefs[CURRENT_STREAK] ?: 0
            var best = prefs[BEST_STREAK] ?: 0

            // One-time port from legacy `LOGGED_DAYS` memory state
            if (lastOpenStr.isBlank()) {
                val loggedDaysStr = prefs[LOGGED_DAYS] ?: "[]"
                try {
                    val daysList = kotlinx.serialization.json.Json.decodeFromString<List<String>>(loggedDaysStr)
                    val sortedDates = daysList.mapNotNull { 
                        try { java.time.LocalDate.parse(it) } catch(e:Exception){ null } 
                    }.sorted().distinct()
                    
                    var tempBest = 0
                    var tempCurrent = 0
                    var prevDate: java.time.LocalDate? = null
                    
                    for (d in sortedDates) {
                        if (prevDate == null) {
                            tempCurrent = 1
                        } else if (d == prevDate.plusDays(1)) {
                            tempCurrent++
                        } else {
                            tempCurrent = 1
                        }
                        if (tempCurrent > tempBest) tempBest = tempCurrent
                        prevDate = d
                    }
                    
                    var calcCurrent = 0
                    if (sortedDates.contains(today)) {
                        var temp = today
                        while(sortedDates.contains(temp)) { calcCurrent++; temp = temp.minusDays(1) }
                    } else {
                        var temp = today.minusDays(1)
                        while(sortedDates.contains(temp)) { calcCurrent++; temp = temp.minusDays(1) }
                    }
                    
                    current = maxOf(current, calcCurrent)
                    best = maxOf(best, tempBest)
                } catch(e: Exception) {}
            }

            if (lastOpenStr == today.toString()) {
                // Already checked in today, do nothing
            } else if (lastOpenStr == today.minusDays(1).toString()) {
                // Continuation
                current += 1
                prefs[CURRENT_STREAK] = current
                prefs[LAST_OPEN_DATE] = today.toString()
            } else {
                // Streak broken or starting fresh (or migrating from above algorithm)
                if (lastOpenStr.isBlank() && current > 0) {
                     // Since we migrated, don't reset to 1 if we actually have data, but +1 for today!
                     if (!sortedDatesConstContainsToday(prefs, today)) {
                         current += 1 
                     }
                } else {
                    current = 1
                }
                prefs[CURRENT_STREAK] = current
                prefs[LAST_OPEN_DATE] = today.toString()
            }

            if (current > best) {
                best = current
            }
            prefs[BEST_STREAK] = best
        }
    }
    
    private fun sortedDatesConstContainsToday(prefs: MutablePreferences, today: java.time.LocalDate): Boolean {
        try {
            val loggedDaysStr = prefs[LOGGED_DAYS] ?: "[]"
            val daysList = kotlinx.serialization.json.Json.decodeFromString<List<String>>(loggedDaysStr)
            return daysList.contains(today.toString())
        } catch(e: Exception) { return false }
    }
    
    suspend fun setCurrentStreak(streak: Int) {
        context.dataStore.edit { it[CURRENT_STREAK] = streak }
    }
    
    suspend fun setBestStreak(streak: Int) {
        context.dataStore.edit { it[BEST_STREAK] = streak }
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
        val encrypted = NotelCrypto.encrypt(token)
        context.dataStore.edit { it[FITBIT_TOKEN] = encrypted }
    }

    suspend fun setFitbitRefreshToken(token: String) {
        val encrypted = NotelCrypto.encrypt(token)
        context.dataStore.edit { it[FITBIT_REFRESH_TOKEN] = encrypted }
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
    suspend fun setTodayAwakeAvgHr(avg: Int) {
        context.dataStore.edit { it[TODAY_AWAKE_AVG_HR] = avg }
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


    suspend fun setIsUnlimited(unlimited: Boolean) {
        context.dataStore.edit { it[IS_UNLIMITED] = unlimited }
    }
    suspend fun setAutoAiSuggestions(enabled: Boolean) {
        context.dataStore.edit { it[AUTO_AI_SUGGESTIONS] = enabled }
    }

    suspend fun setUserContextHidden(hidden: Boolean) {
        context.dataStore.edit { it[USER_CONTEXT_HIDDEN] = hidden }
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
        context.dataStore.edit {
            it[REDDIT_SUBREDDITS] = jsonArray
        }
    }

    suspend fun setRedditSummaries(text: String) {
        context.dataStore.edit { it[REDDIT_SUMMARIES] = text }
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

    suspend fun setProjectReminderEnabled(enabled: Boolean) {
        context.dataStore.edit { it[PROJECT_REMINDER_ENABLED] = enabled }
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

    suspend fun setShareDataWithFriends(enabled: Boolean) {
        context.dataStore.edit { it[SHARE_DATA_WITH_FRIENDS] = enabled }
    }

    suspend fun setTodaySleepMins(mins: Int) {
        context.dataStore.edit { it[TODAY_SLEEP_MINS] = mins }
    }

    suspend fun setTodayAvgHrShared(avg: Int) {
        context.dataStore.edit { it[TODAY_AVG_HR] = avg }
    }

    suspend fun setTodayScore(score: Int) {
        context.dataStore.edit { it[TODAY_SCORE] = score }
    }
 
    suspend fun setTodaySpikes(spikes: Int) {
        context.dataStore.edit { it[TODAY_SPIKES] = spikes }
    }
 
    suspend fun setTodaySleepDebt(debt: Int) {
        context.dataStore.edit { it[TODAY_SLEEP_DEBT] = debt }
    }

    suspend fun setFocusState(json: String) {
        context.dataStore.edit { it[FOCUS_STATE] = json }
    }

    suspend fun setUserNickname(nickname: String) {
        context.dataStore.edit { it[USER_NICKNAME] = nickname }
    }

    suspend fun setUserTag(tag: String) {
        context.dataStore.edit { it[USER_TAG] = tag }
    }

    suspend fun setCupTheorySeen(seen: Boolean) {
        context.dataStore.edit { it[CUP_THEORY_SEEN] = seen }
    }

    suspend fun setLastDynamicNotificationDate(date: String) {
        context.dataStore.edit { it[LAST_DYNAMIC_NOTIFICATION_DATE] = date }
    }

    suspend fun setLastKnownStats(json: String) {
        context.dataStore.edit { it[LAST_KNOWN_STATS] = json }
    }

    suspend fun setLastKnownLocation(lat: Double, lon: Double, city: String) {
        context.dataStore.edit {
            it[LAST_KNOWN_LAT] = lat
            it[LAST_KNOWN_LON] = lon
            it[LAST_KNOWN_CITY] = city
        }
    }

    suspend fun setTipsAndTricksTopics(topicsJson: String) {
        context.dataStore.edit { it[TIPS_AND_TRICKS_TOPICS] = topicsJson }
    }

    suspend fun setTipsAndTricksAnswers(answersJson: String) {
        context.dataStore.edit { it[TIPS_AND_TRICKS_ANSWERS] = answersJson }
    }

    suspend fun setFoodCheckerHistory(historyJson: String) {
        context.dataStore.edit { it[FOOD_CHECKER_HISTORY] = historyJson }
    }

    suspend fun setFoodCheckerLastQuery(lastQueryJson: String) {
        context.dataStore.edit { it[FOOD_CHECKER_LAST_QUERY] = lastQueryJson }
    }
}

object NotelCrypto {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "NotelPrefsKey"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    private fun getSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val secretKey = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (secretKey != null) {
            return secretKey
        }

        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE
        )
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }

    fun encrypt(plainText: String): String {
        if (plainText.isEmpty()) return ""
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getSecretKey())
            val iv = cipher.iv
            val encryptedBytes = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
            val combined = ByteArray(1 + iv.size + encryptedBytes.size)
            combined[0] = iv.size.toByte()
            System.arraycopy(iv, 0, combined, 1, iv.size)
            System.arraycopy(encryptedBytes, 0, combined, 1 + iv.size, encryptedBytes.size)
            Base64.encodeToString(combined, Base64.NO_WRAP)
        } catch (e: Exception) {
            ""
        }
    }

    fun decrypt(cipherText: String): String {
        if (cipherText.isEmpty()) return ""
        return try {
            val combined = try {
                Base64.decode(cipherText, Base64.NO_WRAP)
            } catch (e: Exception) {
                Base64.decode(cipherText, Base64.DEFAULT)
            }
            val ivSize = combined[0].toInt()
            val iv = ByteArray(ivSize)
            System.arraycopy(combined, 1, iv, 0, ivSize)
            val encryptedBytes = ByteArray(combined.size - 1 - ivSize)
            System.arraycopy(combined, 1 + ivSize, encryptedBytes, 0, encryptedBytes.size)

            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getSecretKey(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(encryptedBytes), Charsets.UTF_8)
        } catch (e: Exception) {
            ""
        }
    }

    fun isLikelyCiphertext(value: String): Boolean {
        if (value.isEmpty()) return false
        return try {
            val decoded = try {
                Base64.decode(value, Base64.NO_WRAP)
            } catch (e: Exception) {
                Base64.decode(value, Base64.DEFAULT)
            }
            decoded.size >= 30 && decoded[0].toInt() == 12
        } catch (e: Exception) {
            false
        }
    }
}
