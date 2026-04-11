package com.notel.notel.data.remote

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.net.URL
import java.util.Locale

@Serializable
data class IpLocationResponse(
    val city: String = "Unknown Location",
    val lat: Double = 40.7128,
    val lon: Double = -74.0060,
    val countryCode: String = "US"
)

@Serializable
data class OpenMeteoResponse(
    val current: CurrentWeather,
    val hourly: HourlyWeather
)

@Serializable
data class CurrentWeather(
    val temperature_2m: Double,
    val weather_code: Int
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
    val windSpeed: Double = 0.0
)

class WeatherApi {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun getDetailedWeather(): WeatherInfo? {
        return try {
            // 1. Get Location from IP (no key needed)
            val locResponseText = URL("http://ip-api.com/json").readText()
            val loc = json.decodeFromString<IpLocationResponse>(locResponseText)
            
            // 2. Determine Units
            val units = if (loc.countryCode == "US") "fahrenheit" else "celsius"
            val unitLabel = if (units == "fahrenheit") "F" else "C"
            
            // 3. Get Weather
            val url = "https://api.open-meteo.com/v1/forecast?latitude=${loc.lat}&longitude=${loc.lon}&current=temperature_2m,weather_code&hourly=uv_index,relative_humidity_2m,wind_speed_10m&forecast_days=1&temperature_unit=$units"
            val responseText = URL(url).readText()
            val data = json.decodeFromString<OpenMeteoResponse>(responseText)
            
            WeatherInfo(
                temp = data.current.temperature_2m.toInt(),
                condition = getWeatherDesc(data.current.weather_code),
                uvIndex = data.hourly.uv_index.firstOrNull() ?: 0.0,
                icon = getWeatherIcon(data.current.weather_code),
                locationName = loc.city,
                unit = unitLabel,
                humidity = data.hourly.relative_humidity_2m?.firstOrNull()?.toInt() ?: 0,
                windSpeed = data.hourly.wind_speed_10m?.firstOrNull() ?: 0.0
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

    private fun getWeatherIcon(code: Int): String {
        return when (code) {
            0 -> "☀️"
            1, 2, 3 -> "⛅"
            45, 48 -> "🌫️"
            51, 53, 55 -> "🌦️"
            61, 63, 65 -> "🌧️"
            71, 73, 75 -> "❄️"
            80, 81, 82 -> "⛈️"
            95, 96, 99 -> "⛈️"
            else -> "❓"
        }
    }
}
