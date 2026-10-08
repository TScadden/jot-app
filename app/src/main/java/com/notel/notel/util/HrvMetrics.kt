package com.notel.notel.util

/**
 * Tabs Lab HRV composite metrics. Pure functions, no Android dependencies.
 *
 * The balance-factor HRV index is adapted from the open-source Manawa Pace app
 * (Copyright 2026 Chris Hilder, Apache License 2.0; see the app's About /
 * third-party-licenses screen). The composite blends RMSSD and SDNN into one
 * number: index = ln(RMSSD) * 15.3 * balanceFactor, where
 * balanceFactor = (RMSSD / SDNN) / 0.5 clamped to [0, 1].
 *
 * The balance factor penalizes presentations where RMSSD is low relative to
 * SDNN, a pattern that can appear in sympathetic-dominant states common in
 * dysautonomia. This is an informational composite only. It is not a medical
 * measurement, not a diagnosis, and does not suggest any treatment.
 */
object HrvMetrics {

    private const val INDEX_SCALE = 15.3
    private const val BALANCE_REFERENCE_RATIO = 0.5

    /**
     * Computes the balance-factor HRV index, or null when the inputs are not
     * usable. Zero or negative RMSSD/SDNN are never real readings (biometric
     * zero-value rule) and always yield null, never a charted or cached value.
     */
    fun balanceFactorHrvIndex(rmssdMs: Double?, sdnnMs: Double?): Double? {
        if (rmssdMs == null || sdnnMs == null) return null
        if (rmssdMs <= 0.0 || sdnnMs <= 0.0) return null
        val balanceFactor = ((rmssdMs / sdnnMs) / BALANCE_REFERENCE_RATIO).coerceIn(0.0, 1.0)
        return kotlin.math.ln(rmssdMs) * INDEX_SCALE * balanceFactor
    }
}
