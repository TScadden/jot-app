package com.notel.notel.data.research

/**
 * Flare Forecast: a deterministic, explainable "crash-risk" score for
 * POTS/MCAS pattern awareness.
 *
 * This is deliberately NOT an AI model and NOT a medical prediction. It is a
 * fixed rule-based score over four signals Tabs already collects, each worth
 * 0-25 points, summed to 0-100. Deterministic + fixed weights = every score
 * is explainable factor by factor, which is exactly what the signature
 * feature needs. All user-facing copy frames it as informational
 * risk-awareness, never diagnosis (Juno sign-off, Oct 2026).
 */
object FlareForecast {

    const val DISCLAIMER =
        "Informational only. This score reflects recent patterns in your own " +
            "tracking data and is not a medical prediction, diagnosis, or advice. " +
            "It does not replace your doctor. If you feel unsafe, get help."

    data class FactorInput(
        /** 7-day HRV trend: most recent value vs 7-day personal mean, as fraction */
        val hrvLatestFraction: Double? = null, // e.g. 0.9 = latest 10% below personal mean
        /** Sleep debt in minutes, accumulated over the last 7 days */
        val sleepDebtMinutes: Double? = null,
        /** HR-spike event counts for the last 7 days (one count per day) */
        val spikeCountsLast7Days: List<Int>? = null,
        /** Symptom entry counts: (last 3 days, previous 3 days) */
        val symptomCounts: Pair<Int, Int>? = null
    )

    enum class Level { LOW, MODERATE, ELEVATED }

    data class Factor(
        val name: String,
        val points: Int,          // 0..25
        val explanation: String,
        val hasData: Boolean
    )

    data class Forecast(
        val score: Int,           // 0..100
        val level: Level,
        val factors: List<Factor>,
        val dataSources: Int,     // how many of the 4 factors had data
        val isSparse: Boolean     // true when too few sources to trust the score
    )

    private fun hrvFactor(fraction: Double?): Factor {
        if (fraction == null) return Factor("HRV trend", 0, "No recent HRV data", false)
        val points = when {
            fraction >= 1.0 -> 0
            fraction >= 0.9 -> 8
            fraction >= 0.8 -> 16
            else -> 25
        }
        val pct = ((1.0 - fraction) * 100).toInt()
        val explanation = when (points) {
            0 -> "HRV at or above your recent average"
            else -> "HRV ${pct}% below your recent average"
        }
        return Factor("HRV trend", points, explanation, true)
    }

    private fun sleepFactor(debtMinutes: Double?): Factor {
        if (debtMinutes == null) return Factor("Sleep debt", 0, "No recent sleep data", false)
        val debtHours = debtMinutes / 60.0
        val points = when {
            debtHours <= 0.5 -> 0
            debtHours <= 2.0 -> 8
            debtHours <= 4.0 -> 16
            else -> 25
        }
        val explanation = if (debtHours <= 0) "No sleep debt this week"
        else "About ${"%.1f".format(debtHours)} hours of sleep debt this week"
        return Factor("Sleep debt", points, explanation, true)
    }

    private fun spikeFactor(counts: List<Int>?): Factor {
        if (counts == null || counts.size < 3) return Factor("HR spikes", 0, "Not enough HR data yet", false)
        val recent = counts.sum()
        val avgPerDay = recent.toDouble() / counts.size
        val points = when {
            avgPerDay < 1.0 -> 0
            avgPerDay < 3.0 -> 8
            avgPerDay < 6.0 -> 16
            else -> 25
        }
        val explanation = "$recent spike events in the last ${counts.size} days"
        return Factor("HR spikes", points, explanation, true)
    }

    private fun symptomFactor(counts: Pair<Int, Int>?): Factor {
        if (counts == null) return Factor("Symptom trend", 0, "Not enough symptom logs yet", false)
        val (recent3, previous3) = counts
        if (recent3 + previous3 == 0) return Factor("Symptom trend", 0, "No symptom entries this week", true)
        val ratio = recent3.toDouble() / (previous3 + 1).toDouble()
        val points = when {
            ratio <= 1.1 -> 0
            ratio <= 1.6 -> 8
            ratio <= 2.5 -> 16
            else -> 25
        }
        val explanation = if (points == 0) "Symptom logging steady" else "Symptom entries up sharply vs last week"
        return Factor("Symptom trend", points, explanation, true)
    }

    fun compute(input: FactorInput): Forecast {
        val factors = listOf(
            hrvFactor(input.hrvLatestFraction),
            sleepFactor(input.sleepDebtMinutes),
            spikeFactor(input.spikeCountsLast7Days),
            symptomFactor(input.symptomCounts)
        )
        val score = factors.sumOf { it.points }.coerceIn(0, 100)
        val sources = factors.count { it.hasData }
        val level = when {
            score < 30 -> Level.LOW
            score < 60 -> Level.MODERATE
            else -> Level.ELEVATED
        }
        return Forecast(
            score = score,
            level = level,
            factors = factors,
            dataSources = sources,
            isSparse = sources < 2
        )
    }

    fun levelLabel(level: Level): String = when (level) {
        Level.LOW -> "Low"
        Level.MODERATE -> "Moderate"
        Level.ELEVATED -> "Elevated"
    }
}
