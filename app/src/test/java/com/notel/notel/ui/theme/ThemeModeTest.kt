package com.notel.notel.ui.theme

import org.junit.Assert.*
import org.junit.Test

/**
 * ThemeMode storage contract (light/dark toggle, 2026-09-27).
 *
 * Pure-logic coverage for the DataStore persistence mapping: what the app
 * writes with setThemeMode() must read back identically, unknown or absent
 * values must fall back to DARK (existing users keep the historical theme).
 */
class ThemeModeTest {

    @Test fun fromStored_parsesAllModes_caseInsensitive() {
        assertEquals(ThemeMode.LIGHT, ThemeMode.fromStored("LIGHT"))
        assertEquals(ThemeMode.DARK, ThemeMode.fromStored("DARK"))
        assertEquals(ThemeMode.SYSTEM, ThemeMode.fromStored("SYSTEM"))
        assertEquals(ThemeMode.LIGHT, ThemeMode.fromStored("light"))
        assertEquals(ThemeMode.SYSTEM, ThemeMode.fromStored("system"))
    }

    @Test fun fromStored_unknownOrAbsent_fallsBackToDark() {
        assertEquals(ThemeMode.DARK, ThemeMode.fromStored(null))
        assertEquals(ThemeMode.DARK, ThemeMode.fromStored(""))
        assertEquals(ThemeMode.DARK, ThemeMode.fromStored("MIDNIGHT"))
        assertEquals(ThemeMode.DARK, ThemeMode.fromStored("dark "))
    }

    @Test fun toStored_roundTrips() {
        for (mode in ThemeMode.values()) {
            assertEquals(mode, ThemeMode.fromStored(ThemeMode.toStored(mode)))
        }
    }

    @Test fun toStored_writesUppercaseNames() {
        assertEquals("LIGHT", ThemeMode.toStored(ThemeMode.LIGHT))
        assertEquals("DARK", ThemeMode.toStored(ThemeMode.DARK))
        assertEquals("SYSTEM", ThemeMode.toStored(ThemeMode.SYSTEM))
    }
}
