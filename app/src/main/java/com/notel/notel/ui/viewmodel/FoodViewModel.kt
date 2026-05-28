package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.GeminiService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import javax.inject.Inject

// Struct for UI
data class FoodTopicLevel(
    val topicName: String,
    val level: String, // "High", "Medium", "Low"
    val reasoning: String
)

data class FoodCheckResult(
    val foodName: String,
    val levels: List<FoodTopicLevel>
)

@HiltViewModel
class FoodViewModel @Inject constructor(
    private val geminiService: GeminiService,
    private val preferences: NotelPreferences
) : ViewModel() {

    private val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage

    // Encyclopedia cache flow: Map of food_name (lowercase) -> FoodCheckResult
    val encyclopedia: StateFlow<Map<String, FoodCheckResult>> = preferences.foodCheckerHistory
        .map { json ->
            parseEncyclopediaJson(json)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyMap())

    // Last query checked results flow
    val lastCheckResults: StateFlow<List<FoodCheckResult>> = preferences.foodCheckerLastQuery
        .map { json ->
            parseLastQueryJson(json)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    // Tapping a recent search item
    val recentSearches: StateFlow<List<String>> = encyclopedia
        .map { map ->
            map.keys.toList().sorted().take(20)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun setSearchQuery(query: String) {
        _searchQuery.value = query
    }

    fun clearError() {
        _errorMessage.value = null
    }

    fun checkFoodLevels(rawInput: String) {
        val input = rawInput.trim()
        if (input.isBlank()) return

        viewModelScope.launch {
            _isLoading.value = true
            _errorMessage.value = null

            try {
                // 1. Parse into separate lowercase trimmed items
                val items = input.split(",")
                    .map { it.trim().lowercase() }
                    .filter { it.isNotEmpty() }
                    .distinct()

                if (items.isEmpty()) {
                    _isLoading.value = false
                    return@launch
                }

                val currentEncyclopedia = encyclopedia.value
                val foundInCache = mutableListOf<FoodCheckResult>()
                val missingFromCache = mutableListOf<String>()

                // 2. Separate cached from uncached items
                for (item in items) {
                    val cached = currentEncyclopedia[item]
                    if (cached != null) {
                        foundInCache.add(cached)
                    } else {
                        missingFromCache.add(item)
                    }
                }

                // 3. If all items exist in cache, update last check instantly (0 API calls!)
                if (missingFromCache.isEmpty()) {
                    saveLastQuery(foundInCache)
                    _isLoading.value = false
                    return@launch
                }

                // 4. Request missing items from Gemini
                val missingListContext = missingFromCache.joinToString(", ")
                val prompt = """
                    Analyze the following list of food items and evaluate their levels/concentrations of key health sensitivity markers:
                    Foods to analyze: $missingListContext
                    
                    Evaluate each food against these exactly five topics:
                    1. "Histamine" (Histamine content or histamine-releasing potential)
                    2. "Sugar" (Sugar content or high Glycemic index load)
                    3. "FODMAP" (High FODMAP content that triggers bloating or IBS)
                    4. "Inflammation" (General inflammatory potential or immune triggers)
                    5. "Oxalate" (Oxalate concentrations triggering kidney or pain symptoms)
                    
                    For each food and each topic, you MUST provide:
                    - "level": MUST be exactly one of "High", "Medium", or "Low".
                    - "reasoning": A very concise, maximum 1-sentence description explaining WHY.
                    
                    You MUST respond with a valid JSON object matching the format below. Do NOT wrap in markdown, do NOT include anything but the raw JSON object.
                    
                    JSON Format Example:
                    {
                      "spinach": {
                        "Histamine": { "level": "High", "reasoning": "Spinach is naturally rich in histamine and can trigger mast cell reactions." },
                        "Sugar": { "level": "Low", "reasoning": "Extremely low glycemic load with negligible sugar." },
                        "FODMAP": { "level": "Low", "reasoning": "Monash rated as low FODMAP and safe for IBS in standard servings." },
                        "Inflammation": { "level": "Low", "reasoning": "Packed with anti-inflammatory antioxidants and flavonoids." },
                        "Oxalate": { "level": "High", "reasoning": "Contains exceptionally high oxalate levels, which can irritate kidneys or tissues." }
                      }
                    }
                """.trimIndent()

                geminiService.getAdvice(emptyList(), emptyMap(), userContext = prompt).onSuccess { aiResponse ->
                    val cleanResponse = cleanJsonResponse(aiResponse)
                    try {
                        val responseObj = JSONObject(cleanResponse)
                        val newResults = mutableListOf<FoodCheckResult>()

                        // Parse each newly evaluated item
                        responseObj.keys().forEach { foodKey ->
                            val foodLower = foodKey.trim().lowercase()
                            val foodObj = responseObj.getJSONObject(foodKey)
                            val topicsList = mutableListOf<FoodTopicLevel>()

                            val coreTopics = listOf("Histamine", "Sugar", "FODMAP", "Inflammation", "Oxalate")
                            for (topic in coreTopics) {
                                val levelObj = foodObj.optJSONObject(topic)
                                val level = levelObj?.optString("level", "Low") ?: "Low"
                                val reasoning = levelObj?.optString("reasoning", "No details available.") ?: "No details available."
                                topicsList.add(FoodTopicLevel(topic, level, reasoning))
                            }

                            newResults.add(FoodCheckResult(foodLower, topicsList))
                        }

                        // Update local Encyclopedia with newly generated items
                        val updatedEncyclopedia = currentEncyclopedia.toMutableMap()
                        newResults.forEach {
                            updatedEncyclopedia[it.foodName] = it
                        }
                        saveEncyclopedia(updatedEncyclopedia)

                        // Compile final result (cached + new) matching the user's initial search query order
                        val finalResult = mutableListOf<FoodCheckResult>()
                        for (item in items) {
                            val res = updatedEncyclopedia[item]
                            if (res != null) {
                                finalResult.add(res)
                            }
                        }

                        saveLastQuery(finalResult)
                    } catch (e: Exception) {
                        e.printStackTrace()
                        _errorMessage.value = "Failed to parse AI food analysis. Please check your food names and retry."
                    }
                }.onFailure {
                    _errorMessage.value = it.message ?: "Failed to contact checker database."
                }
            } catch (e: Exception) {
                e.printStackTrace()
                _errorMessage.value = "Error checking food items. Please check spelling."
            } finally {
                _isLoading.value = false
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

    // JSON Helper parsers
    private fun parseEncyclopediaJson(json: String): Map<String, FoodCheckResult> {
        if (json.isBlank() || json == "{}") return emptyMap()
        return try {
            val map = mutableMapOf<String, FoodCheckResult>()
            val mainObj = JSONObject(json)
            mainObj.keys().forEach { foodKey ->
                val foodObj = mainObj.getJSONObject(foodKey)
                val levelsArr = foodObj.getJSONArray("levels")
                val topicsList = mutableListOf<FoodTopicLevel>()
                for (i in 0 until levelsArr.length()) {
                    val lvlObj = levelsArr.getJSONObject(i)
                    topicsList.add(
                        FoodTopicLevel(
                            topicName = lvlObj.getString("topicName"),
                            level = lvlObj.getString("level"),
                            reasoning = lvlObj.getString("reasoning")
                        )
                    )
                }
                map[foodKey] = FoodCheckResult(foodKey, topicsList)
            }
            map
        } catch (e: Exception) {
            emptyMap()
        }
    }

    private fun parseLastQueryJson(json: String): List<FoodCheckResult> {
        if (json.isBlank() || json == "[]") return emptyList()
        return try {
            val list = mutableListOf<FoodCheckResult>()
            val arr = JSONArray(json)
            for (i in 0 until arr.length()) {
                val foodObj = arr.getJSONObject(i)
                val foodName = foodObj.getString("foodName")
                val levelsArr = foodObj.getJSONArray("levels")
                val topicsList = mutableListOf<FoodTopicLevel>()
                for (j in 0 until levelsArr.length()) {
                    val lvlObj = levelsArr.getJSONObject(j)
                    topicsList.add(
                        FoodTopicLevel(
                            topicName = lvlObj.getString("topicName"),
                            level = lvlObj.getString("level"),
                            reasoning = lvlObj.getString("reasoning")
                        )
                    )
                }
                list.add(FoodCheckResult(foodName, topicsList))
            }
            list
        } catch (e: Exception) {
            emptyList()
        }
    }

    private suspend fun saveEncyclopedia(map: Map<String, FoodCheckResult>) {
        try {
            val mainObj = JSONObject()
            map.forEach { (foodKey, result) ->
                val foodObj = JSONObject()
                foodObj.put("foodName", result.foodName)
                
                val levelsArr = JSONArray()
                result.levels.forEach { lvl ->
                    val lvlObj = JSONObject()
                    lvlObj.put("topicName", lvl.topicName)
                    lvlObj.put("level", lvl.level)
                    lvlObj.put("reasoning", lvl.reasoning)
                    levelsArr.put(lvlObj)
                }
                foodObj.put("levels", levelsArr)
                mainObj.put(foodKey, foodObj)
            }
            preferences.setFoodCheckerHistory(mainObj.toString())
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private suspend fun saveLastQuery(results: List<FoodCheckResult>) {
        try {
            val mainArr = JSONArray()
            results.forEach { result ->
                val foodObj = JSONObject()
                foodObj.put("foodName", result.foodName)
                
                val levelsArr = JSONArray()
                result.levels.forEach { lvl ->
                    val lvlObj = JSONObject()
                    lvlObj.put("topicName", lvl.topicName)
                    lvlObj.put("level", lvl.level)
                    lvlObj.put("reasoning", lvl.reasoning)
                    levelsArr.put(lvlObj)
                }
                foodObj.put("levels", levelsArr)
                mainArr.put(foodObj)
            }
            preferences.setFoodCheckerLastQuery(mainArr.toString())
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
