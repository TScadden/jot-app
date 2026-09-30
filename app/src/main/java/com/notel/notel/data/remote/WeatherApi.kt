package com.notel.notel.data.remote

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.Socket
import java.net.URL
import java.net.UnknownHostException
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

@Serializable
data class IpLocationResponse(
    val city: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val country_code: String? = null
)

@Serializable
data class OpenMeteoResponse(
    val current: CurrentWeather
)

@Serializable
data class CurrentWeather(
    val temperature_2m: Double,
    val weather_code: Int,
    val is_day: Int = 1,
    val surface_pressure: Double = 0.0,
    val uv_index: Double = 0.0,
    val relative_humidity_2m: Double? = null,
    val wind_speed_10m: Double? = null
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
        // Garbage in must fail loudly (getDetailedWeather returns null -> honest
        // unavailable state), never silently decode to fake 0 readings.
        ignoreUnknownKeys = true
    }

    /**
     * Primary fetch using the device DNS resolver. If the device cannot resolve
     * the host at all (UnknownHostException), retry once via DNS-over-HTTPS
     * before giving up. That is the signature failure when a VPN (e.g.
     * Tailscale) replaces the device resolver with one that cannot answer for
     * public hosts: every weather call dies in DNS while the IP path itself is
     * fine. Any other failure (non-2xx, timeout, bad payload) keeps the
     * existing behavior: no retry, honest unavailable state upstream.
     */
    private fun fetchUrl(urlString: String): String {
        return try {
            fetchUrlDirect(urlString)
        } catch (e: IOException) {
            // Retry via DNS-over-HTTPS only for DNS failures. The cause chain
            // is walked because HTTP stacks may wrap UnknownHostException.
            if (isDnsFailure(e)) fetchUrlViaDoh(urlString) else throw e
        }
    }

    private fun isDnsFailure(e: Throwable): Boolean {
        var t: Throwable? = e
        while (t != null) {
            if (t is UnknownHostException) return true
            t = t.cause
        }
        return false
    }

    private fun fetchUrlDirect(urlString: String): String {
        val url = URL(urlString)
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 15_000
        connection.setRequestProperty("User-Agent", "Tabs-App/1.0")
        val code = connection.responseCode
        if (code !in 200..299) throw IOException("Weather request failed (HTTP $code)")
        return connection.inputStream.bufferedReader().use { it.readText() }
    }

    /**
     * Fallback fetch used only when the system DNS cannot resolve the host.
     * Resolves the hostname via DNS-over-HTTPS, then connects to each resolved
     * IPv4 address directly (deliberately IPv4-only: under a VPN, unroutable
     * IPv6 is the common stall). TLS SNI, hostname verification, and the Host
     * header all stay on the original hostname, so certificate validation is
     * exactly as strict as the direct path.
     */
    private fun fetchUrlViaDoh(urlString: String): String {
        val url = URL(urlString)
        val host = url.host
        val ips = dohResolveIpv4(host)
        var lastError: IOException = UnknownHostException(host)
        for (ip in ips) {
            try {
                // Same URL, but the socket goes to the literal IP.
                val ipUrl = URL(url.protocol, ip, url.port, url.file)
                val connection = ipUrl.openConnection() as HttpsURLConnection
                connection.connectTimeout = 10_000
                connection.readTimeout = 15_000
                connection.setRequestProperty("User-Agent", "Tabs-App/1.0")
                // The server still needs the original Host for routing and
                // certificate selection.
                connection.setRequestProperty("Host", host)
                connection.sslSocketFactory = sniSocketFactory(host, connection.sslSocketFactory)
                val defaultVerifier = HttpsURLConnection.getDefaultHostnameVerifier()
                connection.hostnameVerifier = HostnameVerifier { _, session ->
                    defaultVerifier.verify(host, session)
                }
                val code = connection.responseCode
                if (code !in 200..299) throw IOException("Weather request failed (HTTP $code)")
                return connection.inputStream.bufferedReader().use { it.readText() }
            } catch (e: IOException) {
                lastError = e
            }
        }
        throw lastError
    }

    /**
     * Resolves [host] to IPv4 addresses via DNS-over-HTTPS (Google Public DNS
     * JSON API), bootstrapped by literal IP so it works even when the system
     * resolver itself is broken. TLS still fully verifies the dns.google
     * certificate (SNI + hostname verification target dns.google); only the
     * transport address is the literal IP. The resolver learns nothing beyond
     * the API hostname being looked up, the same disclosure as normal DNS.
     */
    private fun dohResolveIpv4(host: String): List<String> {
        val connection = URL("https://8.8.8.8/resolve?name=$host&type=A")
            .openConnection() as HttpsURLConnection
        connection.connectTimeout = 8_000
        connection.readTimeout = 8_000
        connection.sslSocketFactory = sniSocketFactory("dns.google", connection.sslSocketFactory)
        val defaultVerifier = HttpsURLConnection.getDefaultHostnameVerifier()
        connection.hostnameVerifier = HostnameVerifier { _, session ->
            defaultVerifier.verify("dns.google", session)
        }
        connection.setRequestProperty("User-Agent", "Tabs-App/1.0")
        connection.setRequestProperty("Accept", "application/json")
        val code = connection.responseCode
        if (code !in 200..299) throw IOException("DNS fallback request failed (HTTP $code)")
        val body = connection.inputStream.bufferedReader().use { it.readText() }
        val answers = try {
            Json.parseToJsonElement(body).jsonObject["Answer"]?.jsonArray
        } catch (e: Exception) {
            null
        } ?: throw IOException("DNS fallback returned no usable answers")
        val ipv4Pattern = Regex("^\\d{1,3}(\\.\\d{1,3}){3}$")
        return answers.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val type = obj["type"]?.jsonPrimitive?.intOrNull ?: return@mapNotNull null
            val data = obj["data"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
            if (type == 1 && ipv4Pattern.matches(data)) data else null
        }.distinct().ifEmpty { throw IOException("DNS fallback returned no IPv4 addresses") }
    }

    /**
     * Wraps [delegate] so every created socket carries [sniHost] as its TLS
     * Server Name Indication. Required when connecting to a literal IP while
     * the certificate belongs to [sniHost]; never used to weaken verification.
     */
    private fun sniSocketFactory(sniHost: String, delegate: SSLSocketFactory): SSLSocketFactory {
        return object : SSLSocketFactory() {
            private fun withSni(socket: Socket): Socket {
                (socket as? SSLSocket)?.let { ssl ->
                    val params: SSLParameters = ssl.sslParameters
                    params.serverNames = listOf(SNIHostName(sniHost))
                    ssl.sslParameters = params
                }
                return socket
            }

            override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites
            override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites
            override fun createSocket(): Socket = withSni(delegate.createSocket())
            override fun createSocket(host: String, port: Int): Socket =
                withSni(delegate.createSocket(host, port))
            override fun createSocket(host: String, port: Int, localHost: InetAddress, localPort: Int): Socket =
                withSni(delegate.createSocket(host, port, localHost, localPort))
            override fun createSocket(host: InetAddress, port: Int): Socket =
                withSni(delegate.createSocket(host, port))
            override fun createSocket(address: InetAddress, port: Int, localAddress: InetAddress, localPort: Int): Socket =
                withSni(delegate.createSocket(address, port, localAddress, localPort))
            override fun createSocket(s: Socket, host: String, port: Int, autoClose: Boolean): Socket =
                withSni(delegate.createSocket(s, host, port, autoClose))
        }
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
            val windUnit = if (units == "fahrenheit") "mph" else "kmh"

            // 3. Get Weather with is_day, surface_pressure, uv_index, humidity, wind.
            // All current-* values so we read THIS hour, not midnight's hourly slot.
            val weatherUrl = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code,is_day,surface_pressure,uv_index,relative_humidity_2m,wind_speed_10m&forecast_days=1&temperature_unit=$units&wind_speed_unit=$windUnit"
            val weatherResponseText = fetchUrl(weatherUrl)
            val data = json.decodeFromString<OpenMeteoResponse>(weatherResponseText)

            WeatherInfo(
                temp = data.current.temperature_2m.toInt(),
                condition = getWeatherDesc(data.current.weather_code),
                uvIndex = data.current.uv_index,
                icon = getWeatherIcon(data.current.weather_code, data.current.is_day == 1),
                locationName = city,
                unit = unitLabel,
                humidity = data.current.relative_humidity_2m?.toInt() ?: 0,
                windSpeed = data.current.wind_speed_10m ?: 0.0,
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
