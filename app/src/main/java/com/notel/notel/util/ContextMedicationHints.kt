package com.notel.notel.util

/**
 * Known-names check for the Personal Context editor.
 *
 * Deliberately narrow (per the Oct 16, 2026 report assessment, rec. (c)#2):
 * the only names scanned for are medications that already exist as entries
 * on the device (active ∪ archived). There is NO general drug-name lexicon
 * here — a name with no entry cannot be detected, and this helper makes no
 * attempt to guess at one.
 *
 * The result feeds a dismissible UI hint in Settings only. It never changes
 * the context text, the medication list, or any other data.
 */
object ContextMedicationHints {

    /**
     * Returns the subset of [medicationNames] that appear in [contextText],
     * in the order the names were supplied, de-duplicated case-insensitively
     * and keeping the entry's own casing.
     *
     * Matching is case-insensitive and boundary-aware: a name matches only
     * when it is not glued to other letters/digits on either side, so
     * "Ivabradine" matches but the "rad" inside a longer word does not.
     * Names shorter than 3 characters are skipped — too collision-prone to
     * hint on.
     */
    fun findMentionedMedicationNames(
        contextText: String,
        medicationNames: Collection<String>
    ): List<String> {
        if (contextText.isBlank()) return emptyList()
        val seen = mutableSetOf<String>()
        val mentioned = mutableListOf<String>()
        for (rawName in medicationNames) {
            val name = rawName.trim()
            if (name.length < 3) continue
            if (!seen.add(name.lowercase())) continue
            val pattern = Regex(
                "(?<![A-Za-z0-9])" + Regex.escape(name) + "(?![A-Za-z0-9])",
                RegexOption.IGNORE_CASE
            )
            if (pattern.containsMatchIn(contextText)) {
                mentioned.add(name)
            }
        }
        return mentioned
    }
}
