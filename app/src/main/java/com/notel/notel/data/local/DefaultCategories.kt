package com.notel.notel.data.local

import com.notel.notel.data.local.entity.Category

/**
 * Default categories seeded into the database on first install.
 * Each has a Material icon name and a hex color.
 */
object DefaultCategories {
    val all = listOf(
        Category(id = 1, name = "Symptoms", icon = "Favorite", colorHex = "#FF6B6B", sortOrder = 0),
        Category(id = 2, name = "Food & Eating",   icon = "Restaurant", colorHex = "#FFB347", sortOrder = 1),
        Category(id = 3, name = "Weight & Vitals", icon = "MonitorWeight", colorHex = "#6BCB77", sortOrder = 2),
        Category(id = 8, name = "Medication",      icon = "Medication", colorHex = "#4ECDC4", sortOrder = 3),
        Category(id = 4, name = "Goals & Habits",  icon = "EmojiEvents", colorHex = "#4D96FF", sortOrder = 4),
        Category(id = 5, name = "Sleep",            icon = "Bedtime", colorHex = "#A566FF", sortOrder = 5),
        Category(id = 6, name = "Mood & Energy",    icon = "Mood", colorHex = "#FFD93D", sortOrder = 6),
        Category(id = 7, name = "General",          icon = "Notes", colorHex = "#B0B0B0", sortOrder = 7),
    )
}
