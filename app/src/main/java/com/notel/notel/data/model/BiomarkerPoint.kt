package com.notel.notel.data.model

import kotlinx.serialization.Serializable

@Serializable
data class BiomarkerPoint(val date: String, val value: Int)
