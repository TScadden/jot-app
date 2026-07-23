package com.notel.notel.util

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.notel.notel.data.local.entity.LogEntry
import java.util.concurrent.TimeUnit

enum class BodyRegionId {
    HEAD,
    EYES,
    LEFT_ARM,
    RIGHT_ARM,
    CHEST,
    ABDOMEN,
    LEFT_SIDE,
    RIGHT_SIDE,
    BACK,
    THIGHS
}

data class EvaluatedBodyImpact(
    val id: String,
    val regionId: BodyRegionId,
    val regionName: String,
    val status: String,
    val details: String,
    val color: Color,
    val icon: ImageVector,
    val timestamp: Long,
    val durationHours: Int = 24,
    val originalLogText: String = "",
    val relatedLogId: Long? = null
) {
    val expiresAt: Long
        get() = timestamp + TimeUnit.HOURS.toMillis(durationHours.toLong())

    fun getTimeRemainingText(now: Long = System.currentTimeMillis()): String {
        val remainingMillis = expiresAt - now
        if (remainingMillis <= 0) return "0m"

        val hours = TimeUnit.MILLISECONDS.toHours(remainingMillis)
        val minutes = TimeUnit.MILLISECONDS.toMinutes(remainingMillis) % 60

        return when {
            hours > 0 -> "${hours}h ${minutes}m"
            minutes > 0 -> "${minutes}m"
            else -> "<1m"
        }
    }
}

object BodyImpactEngine {

    fun evaluateLogs(entries: List<LogEntry>): List<EvaluatedBodyImpact> {
        val now = System.currentTimeMillis()
        val results = mutableListOf<EvaluatedBodyImpact>()

        for (entry in entries) {
            val text = "${entry.body} ${entry.manualText} ${entry.chips}".trim().lowercase()
            val displayText = buildString {
                if (entry.body.isNotBlank()) append(entry.body)
                if (entry.manualText.isNotBlank()) {
                    if (isNotEmpty()) append(" — ")
                    append(entry.manualText)
                }
            }

            // 1. Headaches & Head Symptoms (4-hour duration fade)
            if (containsAny(text, "headache", "migraine", "dizzy", "dizziness", "brain fog", "head pressure")) {
                val duration = 4 // 4 Hours duration for headaches
                val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                if (now < expiresAt) {
                    val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)
                    results.add(
                        EvaluatedBodyImpact(
                            id = "head_${entry.id}",
                            regionId = BodyRegionId.HEAD,
                            regionName = "Head & Neurological",
                            status = "Symptom Active (${ageHours}h ago)",
                            details = "Head symptoms logged. Ensure adequate hydration, rest, and electrolyte balance.",
                            color = Color(0xFFFF7043), // Coral Orange
                            icon = Icons.Default.Psychology,
                            timestamp = entry.timestamp,
                            durationHours = duration,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 2. Labs / Blood Draws (Arm & Veins) - 24-hour duration
            if (containsAny(text, "lab", "blood draw", "bloodwork", "cbc", "venipuncture", "phlebotomy", "blood test")) {
                val duration = 24
                val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                if (now < expiresAt) {
                    val isLeftArm = text.contains("left") || text.contains("l arm")
                    val isRightArm = text.contains("right") || text.contains("r arm")

                    val region = when {
                        isLeftArm -> BodyRegionId.LEFT_ARM
                        isRightArm -> BodyRegionId.RIGHT_ARM
                        else -> BodyRegionId.LEFT_ARM
                    }

                    val name = if (region == BodyRegionId.LEFT_ARM) "Left Arm (Vein Zone)" else "Right Arm (Vein Zone)"
                    val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)

                    results.add(
                        EvaluatedBodyImpact(
                            id = "lab_${entry.id}",
                            regionId = region,
                            regionName = name,
                            status = "Tender / Post-Lab Draw (${ageHours}h ago)",
                            details = "Blood draw logged. Drink extra water today to help replenish fluid & blood volume.",
                            color = Color(0xFFFF5252), // Red
                            icon = Icons.Default.WaterDrop,
                            timestamp = entry.timestamp,
                            durationHours = duration,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 3. Peptide Shots & SubQ Injections (Sides / Flanks / Abdomen) - 48-hour duration for site rotation
            if (containsAny(text, "peptide", "shot", "injection", "subq", "semaglutide", "tirzepatide", "b12", "needle", "pin")) {
                val duration = 48
                val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                if (now < expiresAt) {
                    val isLeftSide = containsAny(text, "left side", "left flank", "left waist", "l side")
                    val isRightSide = containsAny(text, "right side", "right flank", "right waist", "r side")
                    val isAbdomen = containsAny(text, "stomach", "belly", "abdomen", "navel")

                    val region = when {
                        isLeftSide -> BodyRegionId.LEFT_SIDE
                        isRightSide -> BodyRegionId.RIGHT_SIDE
                        isAbdomen -> BodyRegionId.ABDOMEN
                        else -> BodyRegionId.LEFT_SIDE
                    }

                    val regionLabel = when (region) {
                        BodyRegionId.LEFT_SIDE -> "Left Side / Flank"
                        BodyRegionId.RIGHT_SIDE -> "Right Side / Flank"
                        BodyRegionId.ABDOMEN -> "Abdomen Injection Zone"
                        else -> "Injection Zone"
                    }
                    val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)

                    results.add(
                        EvaluatedBodyImpact(
                            id = "injection_${entry.id}",
                            regionId = region,
                            regionName = regionLabel,
                            status = "Peptide / SubQ Shot (${ageHours}h ago)",
                            details = "Injection logged on $regionLabel. Remember to rotate to the opposite side or thigh for your next dose.",
                            color = Color(0xFFAB47BC), // Purple
                            icon = Icons.Default.Vaccines,
                            timestamp = entry.timestamp,
                            durationHours = duration,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 4. Medication Side Effects - Ocular / Eyes - 24-hour duration
            if (containsAny(text, "dry eyes", "blurred vision", "eye strain", "eye pressure", "vision", "eyes")) {
                val duration = 24
                val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                if (now < expiresAt) {
                    val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)
                    results.add(
                        EvaluatedBodyImpact(
                            id = "eyes_${entry.id}",
                            regionId = BodyRegionId.EYES,
                            regionName = "Eyes & Ocular Area",
                            status = "Side Effect Watch (${ageHours}h ago)",
                            details = "Ocular symptoms logged. Keep eyes hydrated with drops and monitor for sensitivity.",
                            color = Color(0xFFFFB300), // Amber
                            icon = Icons.Default.Visibility,
                            timestamp = entry.timestamp,
                            durationHours = duration,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 5. GI / Stomach (Nausea, Upset, Reflux) - 12-hour duration
            if (containsAny(text, "nausea", "stomach ache", "upset stomach", "reflux", "gi distress", "cramps")) {
                val duration = 12
                val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                if (now < expiresAt) {
                    val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)
                    results.add(
                        EvaluatedBodyImpact(
                            id = "stomach_${entry.id}",
                            regionId = BodyRegionId.ABDOMEN,
                            regionName = "Stomach & GI Tract",
                            status = "GI Strain (${ageHours}h ago)",
                            details = "Digestive strain logged. Consider lighter meals and stay hydrated.",
                            color = Color(0xFF26A69A), // Teal
                            icon = Icons.Default.Restaurant,
                            timestamp = entry.timestamp,
                            durationHours = duration,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 6. Back / Spine / Lumbar Pain - 12-hour duration
            if (containsAny(text, "back pain", "back ache", "sharp back pain", "lower back", "upper back", "spine", "lumbar")) {
                val duration = 12 // 12 Hours active window for back pain
                val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                if (now < expiresAt) {
                    val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)
                    results.add(
                        EvaluatedBodyImpact(
                            id = "back_${entry.id}",
                            regionId = BodyRegionId.BACK,
                            regionName = "Back & Spine",
                            status = "Musculoskeletal / Pain (${ageHours}h ago)",
                            details = "Back pain logged. Consider gentle stretching, posture adjustments, or heat therapy.",
                            color = Color(0xFFEF5350), // Crimson Red
                            icon = Icons.Default.FitnessCenter,
                            timestamp = entry.timestamp,
                            durationHours = duration,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }
        }

        // Deduplicate by region, retaining the most recent active impact per body region
        return results
            .sortedByDescending { it.timestamp }
            .distinctBy { it.regionId }
    }

    private fun containsAny(text: String, vararg keywords: String): Boolean {
        return keywords.any { text.contains(it) }
    }
}
