package com.notel.notel.data.remote

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.net.URL

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
    val uv_index: List<Double>
)

data class WeatherInfo(
    val temp: Int,
    val condition: String,
    val uvIndex: Double,
    val icon: String
)

class WeatherApi {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun getLocalWeather(lat: Double = 40.7128, lon: Double = -74.0060): WeatherInfo? {
        return try {
            val url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code&hourly=uv_index&forecast_days=1"
            val responseText = URL(url).readText()
            val data = json.decodeFromString<OpenMeteoResponse>(responseText)
            
            WeatherInfo(
                temp = data.current.temperature_2m.toInt(),
                condition = getWeatherDesc(data.current.weather_code),
                uvIndex = data.hourly.uv_index.firstOrNull() ?: 0.0,
                icon = getWeatherIcon(data.current.weather_code)
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun getWeatherDesc(code: Int): String {
        return when (code) {
            0 -> "Clear"
            1, 2, 3 -> "Partly Cloudy"
            45, 48 -> "Foggy"
            51, 53, 55 -> "Drizzle"
            61, 63, 65 -> "Rainy"
            71, 73, 75 -> "Snowy"
            80, 81, 82 -> "Rain Showers"
            95, 96, 99 -> "Thunderstorm"
            else -> "Unknown"
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
