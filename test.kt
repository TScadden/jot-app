import com.google.gson.Gson
import kotlinx.serialization.json.Json
fun main() {
    try {
        Gson().fromJson("[] x", Any::class.java)
    } catch(e: Exception) {
        println("Gson: " + e.message)
    }
    try {
        Json.parseToJsonElement("[] x")
    } catch(e: Exception) {
        println("Kotlinx: " + e.message)
    }
}
