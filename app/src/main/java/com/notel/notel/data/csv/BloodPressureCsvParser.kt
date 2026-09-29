package com.notel.notel.data.csv

import java.io.InputStream
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import kotlin.math.roundToInt

// ============================================================================
// Blood pressure CSV importer (Phase 1).
//
// PHASE-2 TUNING GUIDE (founder's real CSV):
//   * Column headers: edit HEADER_ALIASES below. Headers are normalized before
//     matching (lowercased, anything in parentheses stripped, whitespace
//     collapsed), so add aliases in their NORMALIZED form, e.g. "sys mmhg"
//     matches a header of "SYS (mmHg)".
//   * Date formats: edit DATE_FORMATS below. Detection tries each pattern in
//     order against the first data row that has a date; the first full-string
//     match wins and is applied to every row. Add new patterns anywhere in the
//     list; earlier entries take precedence on ambiguous dates (e.g. 03/04/2026
//     is read as US M/d/yyyy before EU d.M.yyyy because the US patterns come
//     first).
//   * Validation bounds: edit MAX_SYSTOLIC / MAX_DIASTOLIC below.
// ============================================================================

/** Maximum CSV file size accepted for import (5 MB). */
const val MAX_CSV_FILE_BYTES: Int = 5 * 1024 * 1024

/** Maximum number of data rows accepted for import. */
const val MAX_CSV_DATA_ROWS: Int = 10_000

/** Upper sanity bounds for a single reading; rows above these are skipped as invalid. */
const val MAX_SYSTOLIC: Int = 400
const val MAX_DIASTOLIC: Int = 300

/**
 * Header aliases, keyed by logical column. Compared against the NORMALIZED
 * header (lowercase, parenthetical units removed, whitespace collapsed), so
 * "Systolic (mmHg)" normalizes to "systolic mmhg" and matches.
 *
 * Add variants here when a real-world export uses a header we don't recognize.
 */
val HEADER_ALIASES: Map<String, Set<String>> = mapOf(
    "systolic" to setOf(
        "sys", "systolic", "systolic mmhg", "sys mmhg", "sys bp", "systolic bp",
        "sbp", "systolic pressure", "upper", "systole"
    ),
    "diastolic" to setOf(
        "dia", "diastolic", "diastolic mmhg", "dia mmhg", "dia bp", "diastolic bp",
        "dbp", "diastolic pressure", "lower", "diastole"
    ),
    // Pulse is accepted but intentionally ignored: BloodPressureUiRecord has no
    // pulse field, so there is nowhere to store it. Phase 2 may add one.
    "pulse" to setOf(
        "pulse", "pulse bpm", "pulse rate", "heart rate", "heart rate bpm",
        "hr", "bpm"
    ),
    "date" to setOf(
        "date", "measurement date", "date of measurement", "reading date",
        "day", "measurement day"
    ),
    "time" to setOf(
        "time", "measurement time", "time of measurement", "reading time"
    ),
    "datetime" to setOf(
        "datetime", "date time", "date/time", "measurement datetime",
        "timestamp", "measured at", "reading datetime", "recorded at"
    )
)

/**
 * Date/time formats tried IN ORDER during format detection. The first pattern
 * that fully parses the first data row's date value wins and is used for every
 * row in the file. All parsing uses Locale.US (for AM/PM markers) and is
 * non-lenient. Parsed instants are interpreted in the device's local timezone
 * unless the value carries its own offset (the XXX patterns).
 *
 * Add new patterns here when a real-world export uses a format we don't parse.
 */
val DATE_FORMATS: List<String> = listOf(
    "yyyy-MM-dd'T'HH:mm:ssXXX", // 2026-09-20T08:15:00+02:00
    "yyyy-MM-dd'T'HH:mm:ss",   // 2026-09-20T08:15:00
    "yyyy-MM-dd'T'HH:mm",      // 2026-09-20T08:15
    "yyyy-MM-dd HH:mm:ss",     // 2026-09-20 08:15:00
    "yyyy-MM-dd HH:mm",        // 2026-09-20 08:15
    "yyyy-MM-dd",              // 2026-09-20
    "M/d/yyyy h:mm a",         // 9/20/2026 8:15 AM (US)
    "M/d/yyyy",                // 9/20/2026 (US)
    "d.M.yyyy HH:mm",          // 20.9.2026 08:15 (EU)
    "d.M.yyyy",                // 20.9.2026 (EU)
    "dd/MM/yyyy HH:mm",        // 20/09/2026 08:15 (EU)
    "dd/MM/yyyy"               // 20/09/2026 (EU)
)

// --- User-facing failure messages (kept as constants for wording review) ---

const val MSG_NO_HEADERS =
    "Couldn't find blood pressure columns in this file. Make sure the first row has headers like Systolic, Diastolic, and Date."
const val MSG_NO_VALID_ROWS =
    "No valid blood pressure readings found in this file."
const val MSG_NO_DATE_FORMAT =
    "Couldn't understand the date format in this file. Dates should look like 2026-09-20, 9/20/2026, or 20.09.2026."
const val MSG_TOO_LARGE =
    "This file is too large to import. The limit is 5 MB."
const val MSG_TOO_MANY_ROWS =
    "This file has more than 10,000 readings. The limit is 10,000."
const val MSG_READ_FAILED =
    "Couldn't read this file. Please try a different CSV."

/** One successfully parsed reading. Pulse is parsed but dropped (see note above). */
data class CsvParsedReading(
    val systolic: Int,
    val diastolic: Int,
    val timeEpochMs: Long
)

sealed interface CsvParseResult {
    data class Success(
        val readings: List<CsvParsedReading>,
        /** Rows skipped because values were impossible or the date didn't parse. */
        val invalidRowCount: Int,
        /** Duplicate (time, systolic, diastolic) rows found within the file itself. */
        val duplicateRowCount: Int
    ) : CsvParseResult

    data class Failure(val userMessage: String) : CsvParseResult
}

/** Outcome of reading the picked file's bytes with the size cap applied. */
sealed interface CsvReadOutcome {
    data class Ok(val text: String) : CsvReadOutcome
    object TooLarge : CsvReadOutcome
    object Failed : CsvReadOutcome
}

/**
 * Reads [inputStream] as UTF-8 text, stopping if it exceeds [maxBytes].
 * Never throws for size reasons; reports TooLarge instead.
 */
fun readCsvTextCapped(inputStream: InputStream, maxBytes: Int = MAX_CSV_FILE_BYTES): CsvReadOutcome {
    return try {
        val buf = ByteArray(8192)
        var total = 0
        val out = java.io.ByteArrayOutputStream()
        while (true) {
            val n = inputStream.read(buf)
            if (n == -1) break
            total += n
            if (total > maxBytes) return CsvReadOutcome.TooLarge
            out.write(buf, 0, n)
        }
        CsvReadOutcome.Ok(out.toString(Charsets.UTF_8.name()).removePrefix("\uFEFF"))
    } catch (e: Exception) {
        CsvReadOutcome.Failed
    }
}

/**
 * Smart CSV parser for blood pressure exports. Pure function over the file
 * text: no Android APIs, no I/O, safe to call on a background thread. Never
 * throws; all failures are returned as [CsvParseResult.Failure].
 */
object BloodPressureCsvParser {

    fun parse(csvText: String): CsvParseResult {
        return try {
            parseInternal(csvText)
        } catch (e: Exception) {
            CsvParseResult.Failure(MSG_NO_VALID_ROWS)
        }
    }

    private fun parseInternal(csvText: String): CsvParseResult {
        val lines = csvText.lineSequence()
            .map { it.trimEnd('\r') }
            .filter { it.isNotBlank() }
            .toList()
        if (lines.isEmpty()) return CsvParseResult.Failure(MSG_NO_VALID_ROWS)

        // Delimiter detection: comma first, semicolon fallback when the header
        // splits into a single column.
        val headerLine = lines[0]
        var delimiter = ','
        var headerCells = splitCsvLine(headerLine, delimiter).map { it.trim() }
        if (headerCells.size <= 1) {
            val semi = splitCsvLine(headerLine, ';').map { it.trim() }
            if (semi.size > 1) {
                delimiter = ';'
                headerCells = semi
            }
        }

        val colIndex = mapHeaderColumns(headerCells)
            ?: return CsvParseResult.Failure(MSG_NO_HEADERS)
        val sysIdx = colIndex.getValue("systolic")
        val diaIdx = colIndex.getValue("diastolic")
        val dateIdx = colIndex["date"]
        val timeIdx = colIndex["time"]
        val datetimeIdx = colIndex["datetime"]
        // "pulse" index is deliberately unused: accepted, parsed nowhere, stored nowhere.

        if (datetimeIdx == null && dateIdx == null) {
            return CsvParseResult.Failure(MSG_NO_HEADERS)
        }

        // Date-format detection from the first data row carrying a date value.
        val dateValueOf: (List<String>) -> String = { cells ->
            when {
                datetimeIdx != null -> cells.getOrElse(datetimeIdx) { "" }.trim()
                else -> {
                    val d = cells.getOrElse(dateIdx!!) { "" }.trim()
                    val t = if (timeIdx != null) cells.getOrElse(timeIdx) { "" }.trim() else ""
                    if (d.isNotEmpty() && t.isNotEmpty()) "$d $t" else d
                }
            }
        }
        val firstDateValue = lines.drop(1).asSequence()
            .take(MAX_CSV_DATA_ROWS + 1)
            .map { splitCsvLine(it, delimiter) }
            .map(dateValueOf)
            .firstOrNull { it.isNotBlank() }
            ?: return CsvParseResult.Failure(MSG_NO_VALID_ROWS)

        val datePattern = DATE_FORMATS.firstOrNull { tryParseDate(firstDateValue, it) != null }
            ?: return CsvParseResult.Failure(MSG_NO_DATE_FORMAT)

        val readings = mutableListOf<CsvParsedReading>()
        val seenInFile = mutableSetOf<Triple<Long, Int, Int>>()
        var invalid = 0
        var duplicates = 0
        var dataRowCount = 0

        for (rawLine in lines.drop(1)) {
            dataRowCount++
            if (dataRowCount > MAX_CSV_DATA_ROWS) {
                return CsvParseResult.Failure(MSG_TOO_MANY_ROWS)
            }
            val cells = splitCsvLine(rawLine, delimiter)
            val sys = parseIntCell(cells.getOrElse(sysIdx) { "" })
            val dia = parseIntCell(cells.getOrElse(diaIdx) { "" })
            val epochMs = tryParseDate(dateValueOf(cells), datePattern)

            if (sys == null || dia == null || epochMs == null || !valuesArePlausible(sys, dia)) {
                invalid++
                continue
            }
            val key = Triple(epochMs, sys, dia)
            if (!seenInFile.add(key)) {
                duplicates++
                continue
            }
            readings.add(CsvParsedReading(sys, dia, epochMs))
        }

        if (readings.isEmpty() && duplicates == 0) {
            return CsvParseResult.Failure(MSG_NO_VALID_ROWS)
        }
        return CsvParseResult.Success(
            readings = readings,
            invalidRowCount = invalid,
            duplicateRowCount = duplicates
        )
    }

    /**
     * Maps normalized headers to logical column names. Requires systolic +
     * diastolic and at least one of (datetime) or (date). Returns null when the
     * headers aren't recognizable as a blood pressure export.
     */
    private fun mapHeaderColumns(headerCells: List<String>): Map<String, Int>? {
        val result = mutableMapOf<String, Int>()
        headerCells.forEachIndexed { index, raw ->
            val normalized = normalizeHeader(raw)
            for ((logical, aliases) in HEADER_ALIASES) {
                if (normalized in aliases && logical !in result) {
                    result[logical] = index
                    break
                }
            }
        }
        if ("systolic" !in result || "diastolic" !in result) return null
        if ("datetime" !in result && "date" !in result) return null
        return result
    }

    private fun normalizeHeader(header: String): String {
        return header.lowercase(Locale.US)
            .replace(Regex("\\(.*?\\)"), "")
            .replace(Regex("\\s+"), " ")
            .trim()
    }

    /**
     * Splits one CSV line on [delimiter], honoring double-quoted fields
     * (including embedded delimiters and escaped "" quotes).
     */
    private fun splitCsvLine(line: String, delimiter: Char): List<String> {
        val out = mutableListOf<String>()
        val sb = StringBuilder()
        var inQuotes = false
        var i = 0
        while (i < line.length) {
            val c = line[i]
            when {
                c == '"' -> {
                    if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
                        sb.append('"')
                        i++
                    } else {
                        inQuotes = !inQuotes
                    }
                }
                c == delimiter && !inQuotes -> {
                    out.add(sb.toString())
                    sb.clear()
                }
                else -> sb.append(c)
            }
            i++
        }
        out.add(sb.toString())
        return out
    }

    /** Parses an integer cell, tolerating decimals ("120.0") and stray spaces; decimals round to the nearest whole number. */
    private fun parseIntCell(raw: String): Int? {
        val t = raw.trim().removeSurrounding("\"").trim()
        if (t.isEmpty()) return null
        return t.toIntOrNull() ?: t.toDoubleOrNull()?.roundToInt()
    }

    private fun valuesArePlausible(sys: Int, dia: Int): Boolean {
        return sys > 0 && dia > 0 &&
            dia <= sys &&
            sys <= MAX_SYSTOLIC && dia <= MAX_DIASTOLIC
    }

    /** Parses [value] with [pattern] only if the WHOLE string is consumed. */
    private fun tryParseDate(value: String, pattern: String): Long? {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return null
        return try {
            val sdf = SimpleDateFormat(pattern, Locale.US)
            sdf.isLenient = false
            val pos = ParsePosition(0)
            val date = sdf.parse(trimmed, pos)
            if (date != null && pos.index == trimmed.length) date.time else null
        } catch (e: Exception) {
            null
        }
    }
}
