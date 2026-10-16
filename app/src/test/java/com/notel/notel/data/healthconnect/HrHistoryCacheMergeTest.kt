package com.notel.notel.data.healthconnect

import com.notel.notel.data.model.BiomarkerPoint
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * Regression tests for the Oct 16, 2026 HR-window shrink: FitbitViewModel's
 * 14-day phase-2 fetch overwrote the 180-day `historical_heart_rate` /
 * `historical_hr_spikes` caches unmerged, shrinking the clinical report's
 * HR window from 172 days to 14 between two runs. The merge in
 * [HrHistoryCacheMerge] is what FitbitViewModel now writes through.
 */
class HrHistoryCacheMergeTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val end: LocalDate = LocalDate.of(2026, 10, 16)

    private fun hrPoints(days: Int, valueFor: (LocalDate) -> Int = { 65 }): List<BiomarkerPoint> =
        (days - 1 downTo 0).map { offset ->
            val date = end.minusDays(offset.toLong())
            BiomarkerPoint(date.toString(), valueFor(date))
        }

    private fun spikes(days: Int, spikeCount: Int = 3): List<DailyHeartRateSummary> =
        (days - 1 downTo 0).map { offset ->
            val date = end.minusDays(offset.toLong())
            DailyHeartRateSummary(
                date = date.toString(), avg = 70, max = 120, min = 50,
                baseline = 55, spikeCount = spikeCount, maxDelta = 65,
                totalReadings = 1000
            )
        }

    @Test
    fun `14-day refresh does not shrink a 172-day heart rate cache`() {
        val existing = hrPoints(172) { 65 }
        val fresh = hrPoints(14) { 77 }

        val merged = HrHistoryCacheMerge.mergeHeartRatePoints(existing, fresh)

        assertEquals(172, merged.size)
        assertEquals(existing.first().date, merged.first().date)
        assertEquals(existing.last().date, merged.last().date)
    }

    @Test
    fun `fresh values win for the days the refresh covers, older days keep cached values`() {
        val existing = hrPoints(30) { 65 }
        val fresh = hrPoints(14) { 77 }

        val merged = HrHistoryCacheMerge.mergeHeartRatePoints(existing, fresh)

        val byDate = merged.associate { it.date to it.value }
        // Oldest 16 days: only in the cache, unchanged.
        existing.take(16).forEach { assertEquals(65, byDate[it.date]) }
        // Newest 14 days: refreshed values.
        fresh.forEach { assertEquals(77, byDate[it.date]) }
    }

    @Test
    fun `empty fresh fetch preserves the existing cache instead of wiping it`() {
        val existing = hrPoints(180)

        assertEquals(existing, HrHistoryCacheMerge.mergeHeartRatePoints(existing, emptyList()))
        assertEquals(spikes(180), HrHistoryCacheMerge.mergeHrSpikes(spikes(180), emptyList()))
    }

    @Test
    fun `merged cache is capped at 180 days, dropping the oldest`() {
        val existing = hrPoints(180)
        val newDay = BiomarkerPoint(end.plusDays(1).toString(), 70)

        val merged = HrHistoryCacheMerge.mergeHeartRatePoints(existing, listOf(newDay))

        assertEquals(HrHistoryCacheMerge.MAX_CACHED_DAYS, merged.size)
        assertEquals(newDay.date, merged.last().date)
        assertFalse(merged.any { it.date == existing.first().date })
    }

    @Test
    fun `zero values are failed reads - never stored and never overwrite a real value`() {
        val existing = hrPoints(14) { 65 }
        val freshWithZero = listOf(BiomarkerPoint(end.toString(), 0))

        val merged = HrHistoryCacheMerge.mergeHeartRatePoints(existing, freshWithZero)

        assertEquals(65, merged.last { it.date == end.toString() }.value)
        assertTrue(merged.all { it.value > 0 })
    }

    @Test
    fun `14-day refresh does not shrink a 172-day spikes cache and fresh spike counts win`() {
        val existing = spikes(172, spikeCount = 3)
        val fresh = spikes(14, spikeCount = 9)

        val merged = HrHistoryCacheMerge.mergeHrSpikes(existing, fresh)

        assertEquals(172, merged.size)
        assertEquals(existing.first().date, merged.first().date)
        assertEquals(3, merged.first().spikeCount)
        assertEquals(9, merged.last().spikeCount)
    }

    @Test
    fun `persistence round trip - merged JSON written by the 14-day path still decodes to the full window`() {
        // Mirrors FitbitViewModel's write exactly: decode the existing cache
        // JSON, merge the fresh 14 days, encode, decode again.
        val existingJson = json.encodeToString(hrPoints(172) { 65 })
        val existing = json.decodeFromString<List<BiomarkerPoint>>(existingJson)
        val fresh = hrPoints(14) { 77 }

        val writtenJson = json.encodeToString(HrHistoryCacheMerge.mergeHeartRatePoints(existing, fresh))
        val reread = json.decodeFromString<List<BiomarkerPoint>>(writtenJson)

        assertEquals(172, reread.size)
        assertEquals(65, reread.first().value)
        assertEquals(77, reread.last().value)
    }

    @Test
    fun `results are sorted ascending by date regardless of input order`() {
        val merged = HrHistoryCacheMerge.mergeHeartRatePoints(
            hrPoints(30).reversed(),
            hrPoints(14).reversed()
        )

        assertEquals(merged.map { it.date }.sorted(), merged.map { it.date })
    }
}
