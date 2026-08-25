package com.notel.notel.util

import java.util.regex.Pattern

enum class ProposalIntent {
    MEDICATION,
    SYMPTOM,
    NOTE
}

data class ParsedProposal(
    val type: String, // "MEDICATION", "SYMPTOM", "NOTE"
    val categorySlug: String,
    val title: String,
    val detailText: String,
    val timeString: String? = null,
    val dosage: String? = null,
    val intensity: String? = null,
    val confidence: Float,
    val sourceText: String
) {
    val intent: ProposalIntent
        get() = try { ProposalIntent.valueOf(type) } catch (e: Exception) { ProposalIntent.NOTE }

    val summaryText: String
        get() = if (detailText.isNotBlank()) "$title ($detailText)" else title
}

object QuickAddParser {
    private val TIME_PATTERN = Pattern.compile("(?i)\\b(\\d{1,2}(?::\\d{2})?\\s*(?:am|pm)?)\\b")
    private val DOSAGE_PATTERN = Pattern.compile("(?i)\\b(\\d+(?:\\.\\d+)?\\s*(?:mg|g|mcg|ml|tablets?|pills?|capsules?|units?))\\b")
    private val INTENSITY_PATTERN = Pattern.compile("(?i)\\b(mild|moderate|severe|extreme|slight|bad|\\d{1,2}/10)\\b")

    private val MEDICATION_KEYWORDS = "took take taking medication med meds pill tablet capsule advil tylenol ibuprofen aspirin paracetamol metformin adderall vyvanse synthroid lysinopril amlodipine omeprazole gabapentin atorvastatin"
        .splitWords()

    private val SYMPTOM_KEYWORDS = "headache pain migraine fatigue nausea dizziness fever chills cramps ache soreness stiffness fog anxiety stress cough shortness of breath"
        .splitWords()

    private fun Set<String>.containsAnyIn(text: String): Boolean {
        val tokens = text.lowercase().split("\\s+".toRegex())
        return tokens.any { this.contains(it) }
    }

    private fun String.splitWords(): Set<String> = this.split(" ").toSet()

    fun parseInput(rawInput: String): List<ParsedProposal> {
        val clean = rawInput.trim()
        if (clean.isBlank()) return emptyList()

        // Split multi-intent inputs by sentence or conjunction delimiters (" and ", " then ", ".", ";")
        val clauses = clean.split(Regex("(?i)\\b(?:and|then|also|plus)\\b|;|\\."))
            .map { it.trim() }
            .filter { it.isNotBlank() }

        val proposals = mutableListOf<ParsedProposal>()

        for (clause in clauses) {
            val timeMatcher = TIME_PATTERN.matcher(clause)
            val timeString = if (timeMatcher.find()) timeMatcher.group(1) else null

            val dosageMatcher = DOSAGE_PATTERN.matcher(clause)
            val dosage = if (dosageMatcher.find()) dosageMatcher.group(1) else null

            val intensityMatcher = INTENSITY_PATTERN.matcher(clause)
            val intensity = if (intensityMatcher.find()) intensityMatcher.group(1) else null

            val isMed = MEDICATION_KEYWORDS.containsAnyIn(clause) || dosage != null
            val isSymptom = SYMPTOM_KEYWORDS.containsAnyIn(clause) || intensity != null

            when {
                isMed -> {
                    val confidence = if (dosage != null) 0.95f else 0.80f
                    proposals.add(
                        ParsedProposal(
                            type = "MEDICATION",
                            categorySlug = "medication",
                            title = clause.capitalizeFirst(),
                            detailText = listOfNotNull(dosage, timeString?.let { "at $it" }).joinToString(" "),
                            timeString = timeString,
                            dosage = dosage,
                            confidence = confidence,
                            sourceText = clause
                        )
                    )
                }
                isSymptom -> {
                    val confidence = if (intensity != null) 0.90f else 0.75f
                    proposals.add(
                        ParsedProposal(
                            type = "SYMPTOM",
                            categorySlug = "symptoms",
                            title = clause.capitalizeFirst(),
                            detailText = listOfNotNull(intensity?.let { "Intensity: $it" }, timeString?.let { "at $it" }).joinToString(" "),
                            timeString = timeString,
                            intensity = intensity,
                            confidence = confidence,
                            sourceText = clause
                        )
                    )
                }
                else -> {
                    proposals.add(
                        ParsedProposal(
                            type = "NOTE",
                            categorySlug = "general",
                            title = clause.capitalizeFirst(),
                            detailText = listOfNotNull(timeString?.let { "Logged at $it" }).joinToString(" "),
                            timeString = timeString,
                            confidence = 0.70f,
                            sourceText = clause
                        )
                    )
                }
            }
        }

        return proposals
    }

    fun parse(rawInput: String): List<ParsedProposal> = parseInput(rawInput)

    private fun String.capitalizeFirst(): String {
        if (isEmpty()) return this
        return substring(0, 1).uppercase() + substring(1)
    }
}
