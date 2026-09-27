package com.notel.notel.ui.theme

import org.junit.Assert.*
import org.junit.Test

/**
 * Error-tint ramp (Mira light-mode polish spec, 2026-09-27).
 *
 * Pure-logic coverage for the theme-aware alert ramp: the light ARGB values
 * must match the spec exactly, the dark legacy values must be preserved
 * byte-identically, and the light pairings must meet WCAG AA (4.5:1).
 */
class ErrorTintTest {

    @Test fun lightRamp_matchesSpecArgb() {
        assertEquals(0xFFF9E2E0.toInt(), ErrorTintSurfaceLightArgb.toInt())
        assertEquals(0xFFEFC7C2.toInt(), ErrorTintBorderLightArgb.toInt())
        assertEquals(0xFFF6D9D7.toInt(), ErrorTintStrongLightArgb.toInt())
        assertEquals(0xFF9B1C1C.toInt(), ErrorTintOnLightArgb.toInt())
    }

    @Test fun darkLegacyValues_preserved() {
        // Pre-polish values: #2A121A alert surface, #4A1820 strong fill.
        assertEquals(0xFF2A121A.toInt(), ErrorTintSurfaceDarkArgb.toInt())
        assertEquals(0xFF4A1820.toInt(), ErrorTintStrongDarkArgb.toInt())
    }

    @Test fun glyphOnAlertSurface_meetsAa() {
        assertTrue(
            contrastRatio(ErrorTintOnLightArgb.toInt(), ErrorTintSurfaceLightArgb.toInt()) >= 4.5
        )
    }

    @Test fun glyphOnStrongTint_meetsAa() {
        assertTrue(
            contrastRatio(ErrorTintOnLightArgb.toInt(), ErrorTintStrongLightArgb.toInt()) >= 4.5
        )
    }

    @Test fun whiteBadgeTextOnLightError_meetsAa() {
        // Solid badge fill in light mode is the light palette error #C62828.
        assertTrue(contrastRatio(0xFFFFFFFF.toInt(), 0xFFC62828.toInt()) >= 4.5)
    }

    @Test fun contrastRatio_isSymmetricAndBounded() {
        val a = contrastRatio(0xFF9B1C1C.toInt(), 0xFFF9E2E0.toInt())
        val b = contrastRatio(0xFFF9E2E0.toInt(), 0xFF9B1C1C.toInt())
        assertEquals(a, b, 1e-9)
        assertTrue(a in 1.0..21.0)
        assertEquals(21.0, contrastRatio(0xFF000000.toInt(), 0xFFFFFFFF.toInt()), 0.01)
    }
}
