package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.data.repository.UserListRepository
import com.notel.notel.data.remote.GeminiService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import javax.inject.Inject

@HiltViewModel
class TipsAndTricksViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val userListRepository: UserListRepository,
    private val geminiService: GeminiService,
    private val preferences: NotelPreferences
) : ViewModel() {

    // Topics list flow parsed from cached JSON
    val topics: StateFlow<List<String>> = preferences.tipsAndTricksTopics
        .map { json ->
            if (json.isBlank()) emptyList()
            else {
                try {
                    val arr = JSONArray(json)
                    List(arr.length()) { arr.getString(it) }
                } catch (e: Exception) {
                    emptyList()
                }
            }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    // Answers map flow parsed from cached JSON
    val cachedTips: StateFlow<Map<String, List<String>>> = preferences.tipsAndTricksAnswers
        .map { json ->
            if (json.isBlank()) emptyMap()
            else {
                try {
                    val obj = JSONObject(json)
                    val map = mutableMapOf<String, List<String>>()
                    obj.keys().forEach { key ->
                        val arr = obj.getJSONArray(key)
                        map[key] = List(arr.length()) { arr.getString(it) }
                    }
                    map
                } catch (e: Exception) {
                    emptyMap()
                }
            }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    private val _isLoadingTopics = MutableStateFlow(false)
    val isLoadingTopics: StateFlow<Boolean> = _isLoadingTopics

    private val _loadingTipsTopic = MutableStateFlow<String?>(null)
    val loadingTipsTopic: StateFlow<String?> = _loadingTipsTopic

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage

    fun clearError() {
        _errorMessage.value = null
    }

    // Task 2: Scan User Data (Jots, Lists, Documents) and Generate 4-6 custom topics
    fun generateTopics() {
        viewModelScope.launch {
            _isLoadingTopics.value = true
            _errorMessage.value = null
            try {
                // 1. Gather all local notes/Jots
                val jots = logRepository.getAllEntries().first().take(20)
                val jotsContext = jots.joinToString("\n") { "- [${it.timestamp}]: ${it.body}" }

                // 2. Gather lists
                val lists = userListRepository.lists.first().filter { it.name != "__user_notes__" }
                val listsContext = lists.joinToString(", ") { it.name }

                // 3. Gather document titles
                val docs = logRepository.getAllDocuments().first()
                val docsContext = docs.joinToString(", ") { it.name }

                // 4. Construct lightweight token-efficient prompt
                val prompt = """
                    You are a personalized assistant helping a user discover insights about their life, habits, health, and data.
                    Read this compact summary of their records:
                    
                    JOTS:
                    $jotsContext
                    
                    LISTS:
                    $listsContext
                    
                    DOCUMENTS UPLOADED:
                    $docsContext
                    
                    Based ONLY on their records, propose exactly 4 to 6 specific, open-ended questions they might want to ask to get tips, tricks, and insights (e.g., "How can I improve my sleep pattern based on my sleep logs?", "What tips can help me manage my medication list?", "How should I structure my symptom tracking?"). Make them very personal and tailored to the actual contents of their Jots, lists, and docs.
                    
                    You MUST return a JSON array of strings ONLY. No markdown, no wrapping code blocks, no explanation, just raw JSON.
                    Example format:
                    ["Question 1?", "Question 2?", "Question 3?", "Question 4?"]
                """.trimIndent()

                // 5. Call Gemini Service
                geminiService.getAdvice(emptyList(), emptyMap(), userContext = prompt).onSuccess { aiResponse ->
                    val cleanResponse = cleanJsonResponse(aiResponse)
                    try {
                        val arr = JSONArray(cleanResponse)
                        val topicList = List(arr.length()) { arr.getString(it) }
                        if (topicList.isNotEmpty()) {
                            // Cache to NotelPreferences
                            preferences.setTipsAndTricksTopics(cleanResponse)
                            // Clear old cached answers since topics changed
                            preferences.setTipsAndTricksAnswers("")
                        } else {
                            _errorMessage.value = "Failed to parse topics list from server."
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                        _errorMessage.value = "Failed to decode topics. Please try again."
                    }
                }.onFailure {
                    _errorMessage.value = it.message ?: "Network error. Please try again."
                }
            } catch (e: Exception) {
                e.printStackTrace()
                _errorMessage.value = e.message ?: "Failed to scan records."
            } finally {
                _isLoadingTopics.value = false
            }
        }
    }

    // Task 3: Generate 3-5 high-density, actionable tips for a selected topic
    fun fetchTipsForTopic(topic: String) {
        viewModelScope.launch {
            if (cachedTips.value.containsKey(topic)) return@launch // Already cached!

            _loadingTipsTopic.value = topic
            _errorMessage.value = null
            try {
                // 1. Gather all local notes/Jots for details
                val jots = logRepository.getAllEntries().first().take(20)
                val jotsContext = jots.joinToString("\n") { "- ${it.body}" }

                // 2. Propose prompt for Gemini
                val prompt = """
                    The user has chosen to learn more about the following topic based on their personal records:
                    "$topic"
                    
                    Here are their recent journal records for reference:
                    $jotsContext
                    
                    Provide 3 to 5 highly concise, actionable, and personalized tips or tricks.
                    - Keep it short, high-density, and structured.
                    - Return ONLY a JSON array of strings, where each string represents a single tip.
                    - Do NOT use markdown code blocks, do NOT explain. Just return a raw JSON array.
                    
                    Example format:
                    ["Tip 1 details...", "Tip 2 details...", "Tip 3 details..."]
                """.trimIndent()

                geminiService.getAdvice(emptyList(), emptyMap(), userContext = prompt).onSuccess { aiResponse ->
                    val cleanResponse = cleanJsonResponse(aiResponse)
                    try {
                        val arr = JSONArray(cleanResponse)
                        val tipsList = List(arr.length()) { arr.getString(it) }
                        if (tipsList.isNotEmpty()) {
                            // Update cached map in NotelPreferences
                            val currentMap = cachedTips.value.toMutableMap()
                            currentMap[topic] = tipsList
                            
                            val obj = JSONObject()
                            currentMap.forEach { (k, v) ->
                                val jArr = JSONArray(v)
                                obj.put(k, jArr)
                            }
                            preferences.setTipsAndTricksAnswers(obj.toString())
                        } else {
                            _errorMessage.value = "Failed to parse tips."
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                        _errorMessage.value = "Could not decode tips. Please retry."
                    }
                }.onFailure {
                    _errorMessage.value = it.message ?: "Failed to generate tips."
                }
            } catch (e: Exception) {
                e.printStackTrace()
                _errorMessage.value = e.message ?: "Error getting tips."
            } finally {
                _loadingTipsTopic.value = null
            }
        }
    }

    private fun cleanJsonResponse(raw: String): String {
        var clean = raw.trim()
        if (clean.startsWith("```json")) {
            clean = clean.removePrefix("```json")
        } else if (clean.startsWith("```")) {
            clean = clean.removePrefix("```")
        }
        if (clean.endsWith("```")) {
            clean = clean.removeSuffix("```")
        }
        return clean.trim()
    }
}
