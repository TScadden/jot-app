package com.notel.notel.util

import java.time.Clock
import java.time.LocalDate
import java.time.ZoneId
import javax.inject.Inject
import javax.inject.Singleton

interface TimeProvider {
    fun clock(): Clock
    fun zoneId(): ZoneId = clock().zone
    fun today(): LocalDate = LocalDate.now(clock())
    fun nowEpochMilli(): Long = clock().millis()
}

@Singleton
class DefaultTimeProvider @Inject constructor() : TimeProvider {
    override fun clock(): Clock = Clock.systemDefaultZone()
}

class TestTimeProvider(
    private var testClock: Clock = Clock.system(ZoneId.systemDefault())
) : TimeProvider {
    override fun clock(): Clock = testClock
    fun setClock(clock: Clock) { testClock = clock }
}
