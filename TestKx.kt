import kotlinx.serialization.json.Json
fun main() {
    try {
        Json.parseToJsonElement("[] x")
    } catch(e: Exception) {
        println(e.message)
    }
}
