package com.notel.notel.data.remote

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.net.HttpURLConnection
import java.net.URL

@Serializable
data class IpLocationResponse(
    val city: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val country_code: String? = null
)

@Serializable
data class OpenMeteoResponse(
    val current: CurrentWeather,
    val hourly: HourlyWeather
)

@Serializable
data class CurrentWeather(
    val temperature_2m: Double,
    val weather_code: Int,
    val is_day: Int = 1,
    val surface_pressure: Double = 0.0
)

@Serializable
data class HourlyWeather(
    val uv_index: List<Double>,
    val relative_humidity_2m: List<Double>? = null,
    val wind_speed_10m: List<Double>? = null
)

data class WeatherInfo(
    val temp: Int,
    val condition: String,
    val uvIndex: Double,
    val icon: String,
    val locationName: String,
    val unit: String,
    val humidity: Int = 0,
    val windSpeed: Double = 0.0,
    val pressure: Double = 0.0
)

class WeatherApi {
    private val json = Json { 
        ignoreUnknownKeys = true 
        coerceInputValues = true
    }

    private fun fetchUrl(urlString: String): String {
        val url = URL(urlString)
        val connection = url.openConnection() as HttpURLConnection
        connection.setRequestProperty("User-Agent", "Notel-App/1.0")
        return connection.inputStream.bufferedReader().use { it.readText() }
    }

    /**
     * Fetches detailed weather. If lat/lon/cityName are provided (e.g. from GPS),
     * it bypasses IP-based geolocation for maximum precision.
     */
    suspend fun getDetailedWeather(
        manualLat: Double? = null,
        manualLon: Double? = null,
        manualCity: String? = null
    ): WeatherInfo? {
        return try {
            val lat: Double
            val lon: Double
            val city: String
            val countryCode: String

            if (manualLat != null && manualLon != null) {
                lat = manualLat
                lon = manualLon
                city = manualCity ?: "Current Location"
                countryCode = "US" // Default to US units if forced, Geocoder could refine this
            } else {
                // Fallback to IP Geolocation
                val locResponseText = fetchUrl("https://ipinfo.io/json")
                val jsonObject = Json.parseToJsonElement(locResponseText).jsonObject
                city = jsonObject["city"]?.jsonPrimitive?.content ?: "Unknown"
                val loc = jsonObject["loc"]?.jsonPrimitive?.content?.split(",") ?: listOf("40.7128", "-74.0060")
                countryCode = jsonObject["country"]?.jsonPrimitive?.content ?: "US"
                lat = loc[0].toDoubleOrNull() ?: 40.7128
                lon = loc[1].toDoubleOrNull() ?: -74.0060
            }
            
            // 2. Determine Units
            val units = if (countryCode == "US") "fahrenheit" else "celsius"
            val unitLabel = if (units == "fahrenheit") "F" else "C"
            
            // 3. Get Weather with is_day and surface_pressure
            val weatherUrl = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code,is_day,surface_pressure&hourly=uv_index,relative_humidity_2m,wind_speed_10m&forecast_days=1&temperature_unit=$units"
            val weatherResponseText = fetchUrl(weatherUrl)
            val data = json.decodeFromString<OpenMeteoResponse>(weatherResponseText)
            
            WeatherInfo(
                temp = data.current.temperature_2m.toInt(),
                condition = getWeatherDesc(data.current.weather_code),
                uvIndex = data.hourly.uv_index.firstOrNull() ?: 0.0,
                icon = getWeatherIcon(data.current.weather_code, data.current.is_day == 1),
                locationName = city,
                unit = unitLabel,
                humidity = data.hourly.relative_humidity_2m?.firstOrNull()?.toInt() ?: 0,
                windSpeed = data.hourly.wind_speed_10m?.firstOrNull() ?: 0.0,
                pressure = data.current.surface_pressure
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun getWeatherDesc(code: Int): String {
        return when (code) {
            0 -> "Clear Sky"
            1, 2, 3 -> "Partly Cloudy"
            45, 48 -> "Foggy Conditions"
            51, 53, 55 -> "Light Drizzle"
            61, 63, 65 -> "Continuous Rain"
            71, 73, 75 -> "Snowfall"
            80, 81, 82 -> "Rain Showers"
            95, 96, 99 -> "Thunderstorm"
            else -> "Atmospheric Conditions"
        }
    }

    private fun getWeatherIcon(code: Int, isDay: Boolean): String {
        return when (code) {
            0 -> if (isDay) "☀️" else "🌙"
            1, 2, 3 -> if (isDay) "⛅" else "☁️"
            45, 48 -> "🌫️"
            51, 53, 55 -> "🌦️"
            61, 63, 65 -> "🌧️"
            71, 73, 75 -> "❄️"
            80, 81, 82 -> "⛈️"
            95, 96, 99 -> "⛈️"
            else -> if (isDay) "☀️" else "🌙"
        }
    }
}
