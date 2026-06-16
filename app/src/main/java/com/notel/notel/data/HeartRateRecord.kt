package com.notel.notel.data

import kotlinx.serialization.Serializable

data class HeartRateRecord(val timestamp: String, val bpm: Int)

@Serializable
data class TelemetryPoint(val timestamp: Long, val bpm: Int)
