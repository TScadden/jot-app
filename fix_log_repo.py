import re
with open("/Users/Tysonn/AndroidStudioProjects/Notel/app/src/main/java/com/notel/notel/data/repository/LogRepository.kt", "r") as f:
    content = f.read()

content = content.replace(
    "import com.notel.notel.data.remote.GeminiService",
    "import com.notel.notel.data.remote.GeminiService\nimport com.notel.notel.data.healthconnect.HealthConnectManager"
)

content = content.replace(
    "class LogRepository @Inject constructor(\n    private val logEntryDao: LogEntryDao,\n    private val geminiService: GeminiService,\n    private val preferences: NotelPreferences\n)",
    "class LogRepository @Inject constructor(\n    private val logEntryDao: LogEntryDao,\n    private val geminiService: GeminiService,\n    private val preferences: NotelPreferences,\n    private val healthConnectManager: HealthConnectManager\n)"
)

# Fix fitbit logic
fitbit_logic_1 = """        val fitbitToken = preferences.fitbitToken.first()
        val fitbitData = if (fitbitToken.isNotBlank()) {
            val heart = fitbitService.getHistoricalHeartRate(fitbitToken).getOrNull()?.let { hist ->"""
new_logic_1 = """        val hasHealthConnect = healthConnectManager.hasAllPermissions()
        val fitbitData = if (hasHealthConnect) {
            val heart = healthConnectManager.readHistoricalHeartRate().let { hist ->"""
content = content.replace(fitbit_logic_1, new_logic_1)

content = content.replace("fitbitService.getHistoricalSleep(fitbitToken).getOrNull()", "healthConnectManager.readHistoricalSleep()")
content = content.replace("fitbitService.getHistoricalCalories(fitbitToken).getOrNull()", "healthConnectManager.readHistoricalCalories()")

content = content.replace("""        val fitbitToken = preferences.fitbitToken.first()
        
        val fitbitData = if (fitbitToken.isNotBlank()) {
            val heart = fitbitService.getHistoricalHeartRate(fitbitToken).getOrNull()?.take(7)?.map{ it.second }?.let { hist ->""", """        val hasHealthConnect = healthConnectManager.hasAllPermissions()
        
        val fitbitData = if (hasHealthConnect) {
            val heart = healthConnectManager.readHistoricalHeartRate().take(7).map{ it.second }.let { hist ->""")


with open("/Users/Tysonn/AndroidStudioProjects/Notel/app/src/main/java/com/notel/notel/data/repository/LogRepository.kt", "w") as f:
    f.write(content)
