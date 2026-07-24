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
    THIGHS,
    PEPTIDE,
    SYSTEMIC
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
    val durationMinutes: Int = 24 * 60,
    val durationHours: Int = durationMinutes / 60,
    val originalLogText: String = "",
    val relatedLogId: Long? = null
) {
    val expiresAt: Long
        get() = timestamp + TimeUnit.MINUTES.toMillis(durationMinutes.toLong())

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

            // Dynamic AI Duration & Impact Parser Heuristics (Short, Realistic Recovery Windows)
            val textLower = text
            val isSevere = containsAny(textLower, "sharp", "severe", "extreme", "terrible", "intense", "heavy")
            val isMild = containsAny(textLower, "mild", "slight", "minor", "dull", "light")

            // 1. Headaches & Neurological (Short 1-3 hour active window)
            if (containsAny(textLower, "headache", "migraine", "dizzy", "dizziness", "brain fog", "head pressure")) {
                val duration = when {
                    textLower.contains("migraine") -> if (isSevere) 6 else 4
                    isSevere -> 3
                    isMild -> 1
                    else -> 2 // 2 hours default for standard headache
                }
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
                            color = Color(0xFFFF7043),
                            icon = Icons.Default.Psychology,
                            timestamp = entry.timestamp,
                            durationMinutes = duration * 60,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 2. Labs / Blood Draws (Arm & Veins) (4 hour active window)
            if (containsAny(textLower, "lab", "blood draw", "bloodwork", "cbc", "venipuncture", "phlebotomy", "blood test")) {
                val duration = if (isSevere || textLower.contains("multiple")) 6 else 4
                val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                if (now < expiresAt) {
                    val isLeftArm = textLower.contains("left") || textLower.contains("l arm")
                    val isRightArm = textLower.contains("right") || textLower.contains("r arm")

                    val region = when {
                        isLeftArm -> BodyRegionId.LEFT_ARM
                        isRightArm -> BodyRegionId.RIGHT_ARM
                        else -> BodyRegionId.LEFT_ARM
                    }

                    val name = "Arm (Vein Zone)"
                    val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)

                    results.add(
                        EvaluatedBodyImpact(
                            id = "lab_${entry.id}",
                            regionId = region,
                            regionName = name,
                            status = "Tender / Post-Lab Draw (${ageHours}h ago)",
                            details = "Blood draw logged. Drink extra water today to help replenish fluid & blood volume.",
                            color = Color(0xFFFF5252),
                            icon = Icons.Default.WaterDrop,
                            timestamp = entry.timestamp,
                            durationMinutes = duration * 60,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 3. Peptide Shots & SubQ Injections (24 hour site rotation window)
            val isFromMedTab = entry.categoryId == 8 || entry.source == "Medications Tab" || containsAny(textLower, "took medication", "medication:", "took med", "logged from medications tab", "medication & supplements")
            val isExplicitShotAction = (containsAny(textLower, "took peptide", "peptide shot", "injected peptide", "subq shot", "injection of", "injected") || containsAny(entry.chips.lowercase(), "medication", "supplements", "injection"))
            
            if (isFromMedTab || isExplicitShotAction) {
                val isExplicitShot = containsAny(textLower, "peptide", "shot", "injection", "subq", "needle", "pin", "semaglutide", "tirzepatide")
                if (isExplicitShot) {
                    val duration = 24
                    val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                    if (now < expiresAt) {
                        val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)

                        results.add(
                            EvaluatedBodyImpact(
                                id = "injection_${entry.id}",
                                regionId = BodyRegionId.PEPTIDE,
                                regionName = "Peptide Shot",
                                status = "Peptide Shot (${ageHours}h ago)",
                                details = "Peptide shot logged. Remember to rotate to the opposite side or thigh for your next dose.",
                                color = Color(0xFFAB47BC),
                                icon = Icons.Default.Vaccines,
                                timestamp = entry.timestamp,
                                durationMinutes = duration * 60,
                                originalLogText = displayText,
                                relatedLogId = entry.id
                            )
                        )
                    }
                }
            }

            // 4. Medication Side Effects - Ocular / Eyes (12 hour active window)
            if (containsAny(textLower, "dry eyes", "blurred vision", "eye strain", "eye pressure", "vision", "eyes")) {
                val duration = if (isSevere) 18 else 12
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
                            color = Color(0xFFFFB300),
                            icon = Icons.Default.Visibility,
                            timestamp = entry.timestamp,
                            durationMinutes = duration * 60,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 5. GI / Stomach (4-6 hour active window)
            if (containsAny(textLower, "nausea", "stomach ache", "upset stomach", "reflux", "gi distress", "cramps")) {
                val duration = if (isSevere) 8 else 4
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
                            color = Color(0xFF26A69A),
                            icon = Icons.Default.Restaurant,
                            timestamp = entry.timestamp,
                            durationMinutes = duration * 60,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 6. Back / Spine / Lumbar Pain (2-4 hour active window for sharp back pain)
            if (containsAny(textLower, "back pain", "back ache", "sharp back pain", "lower back", "upper back", "spine", "lumbar", "back")) {
                val duration = when {
                    isSevere || textLower.contains("sharp") -> 4 // 4h for sharp back pain
                    isMild -> 1
                    else -> 3 // 3h for standard back pain
                }
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
                            color = Color(0xFFEF5350),
                            icon = Icons.Default.FitnessCenter,
                            timestamp = entry.timestamp,
                            durationMinutes = duration * 60,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }

            // 7. General Pain & Muscle Soreness Catch-All (Chest, Legs, Shoulders, Joints)
            if (containsAny(text, "pain", "sore", "ache", "cramp", "tender", "stiff")) {
                val isChest = containsAny(text, "chest", "rib", "heart")
                val isLeg = containsAny(text, "leg", "thigh", "knee", "calf", "hamstring")
                val isArm = containsAny(text, "bicep", "tricep", "shoulder", "elbow", "wrist")

                val duration = 12
                val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                if (now < expiresAt) {
                    val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)
                    val (region, regionLabel) = when {
                        isChest -> Pair(BodyRegionId.CHEST, "Chest & Ribs")
                        isLeg -> Pair(BodyRegionId.THIGHS, "Legs & Thighs")
                        isArm -> Pair(BodyRegionId.LEFT_ARM, "Arm & Shoulder")
                        else -> Pair(BodyRegionId.BACK, "Musculoskeletal / Back")
                    }

                    // Only add if region isn't already evaluated for a higher-priority match
                    if (results.none { it.regionId == region }) {
                        results.add(
                            EvaluatedBodyImpact(
                                id = "symptom_${entry.id}",
                                regionId = region,
                                regionName = regionLabel,
                                status = "Symptom / Pain (${ageHours}h ago)",
                                details = "Pain or soreness logged. Monitor for changes and rest affected area.",
                                color = Color(0xFFFF7043),
                                icon = Icons.Default.Warning,
                                timestamp = entry.timestamp,
                                durationMinutes = duration * 60,
                                originalLogText = displayText,
                                relatedLogId = entry.id
                            )
                        )
                    }
                }
            }

            // 8. Medication Dose Logging & Side Effect Watch (Excluding Peptide Shots)
            val isExplicitMedSource = entry.categoryId == 8 || entry.source == "Medications Tab" || containsAny(textLower, "took medication", "medication:", "took med", "logged from medications tab")
            val isPeptideOrInjection = containsAny(textLower, "peptide", "shot", "injection", "subq", "needle", "pin")
            if (isExplicitMedSource && !isPeptideOrInjection) {
                // Calculate realistic single-dose duration based on frequency
                val duration = when {
                    containsAny(textLower, "twice daily", "twice a day", "2x daily", "2x a day", "bid", "12h") -> 12
                    containsAny(textLower, "three times", "3x daily", "3x a day", "tid", "8h") -> 8
                    containsAny(textLower, "four times", "4x daily", "4x a day", "qid", "6h") -> 6
                    containsAny(textLower, "once daily", "once a day", "qd", "24h") -> 24
                    else -> 12 // Default to 12 hours for a single dose of standard medications
                }
                val expiresAt = entry.timestamp + TimeUnit.HOURS.toMillis(duration.toLong())

                if (now < expiresAt) {
                    val ageHours = TimeUnit.MILLISECONDS.toHours(now - entry.timestamp)
                    val medName = displayText.substringAfter("Took Medication:").substringAfter("Medication:").substringBefore("(").trim()
                    
                    // Comprehensive medical side-effect lookup based on drug name
                    val medLower = medName.lowercase()
                    val specificDetails = when {
                        medLower.contains("ivabradine") || medLower.contains("corlanor") ->
                            "Ivabradine (7.5mg active). Primary Goal: Lowers heart rate by inhibiting funny current (If). Key Side Effects: Phosphenes (luminous visual bursts), bradycardia (slow heart rate), dizziness, 1st-degree AV block, & fatigue."
                        medLower.contains("semaglutide") || medLower.contains("ozempic") || medLower.contains("wegovy") ->
                            "Semaglutide GLP-1 receptor agonist. Primary Goal: Glycemic control & weight regulation. Key Side Effects: Nausea, delayed gastric emptying, acid reflux, constipation, & fatigue."
                        medLower.contains("tirzepatide") || medLower.contains("mounjaro") || medLower.contains("zepbound") ->
                            "Tirzepatide Dual GIP/GLP-1 agonist. Primary Goal: Metabolic & weight regulation. Key Side Effects: Nausea, mild diarrhea, decreased appetite, & injection site sensitivity."
                        medLower.contains("metformin") ->
                            "Metformin. Primary Goal: Insulin sensitivity. Key Side Effects: GI distress, cramping, B12 depletion watch, & mild nausea."
                        medLower.contains("lisinopril") || medLower.contains("losartan") || medLower.contains("amlodipine") ->
                            "Antihypertensive medication. Primary Goal: Blood pressure management. Key Side Effects: Dizziness on standing, dry cough, mild fatigue, & electrolyte shifts."
                        else ->
                            if (medName.isNotBlank()) "Logged: $medName. Gemini AI monitoring active response. Common Side Effects: Mild dizziness, GI changes, fatigue, & blood pressure shifts." 
                            else "Medication dose logged. Gemini AI tracking systemic side-effects, therapeutic goals, and active duration."
                    }
                    
                    results.add(
                        EvaluatedBodyImpact(
                            id = "med_${entry.id}",
                            regionId = BodyRegionId.SYSTEMIC,
                            regionName = if (medName.isNotBlank()) "Systemic ($medName)" else "Systemic / Medication Active",
                            status = "Medication Active (${ageHours}h ago)",
                            details = specificDetails,
                            color = Color(0xFF4ECDC4),
                            icon = Icons.Default.Medication,
                            timestamp = entry.timestamp,
                            durationMinutes = duration * 60,
                            originalLogText = displayText,
                            relatedLogId = entry.id
                        )
                    )
                }
            }
        }

        // Return all active impacts sorted by most recent timestamp
        return results.sortedByDescending { it.timestamp }
    }

    private fun containsAny(text: String, vararg keywords: String): Boolean {
        return keywords.any { text.contains(it) }
    }
}
