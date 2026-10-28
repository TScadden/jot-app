package com.notel.notel.playground.flutter

import io.sentry.Breadcrumb
import io.sentry.JsonSerializer
import io.sentry.SentryEvent
import io.sentry.SentryLevel
import io.sentry.SentryOptions
import io.sentry.protocol.App
import io.sentry.protocol.Contexts
import io.sentry.protocol.Device
import io.sentry.protocol.Geo
import io.sentry.protocol.Gpu
import io.sentry.protocol.Mechanism
import io.sentry.protocol.Message
import io.sentry.protocol.OperatingSystem
import io.sentry.protocol.Request
import io.sentry.protocol.SentryException
import io.sentry.protocol.SentryRuntime
import io.sentry.protocol.SentryStackFrame
import io.sentry.protocol.SentryStackTrace
import io.sentry.protocol.SentryThread
import io.sentry.protocol.User
import java.io.StringWriter
import java.util.Date
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit test of the native C1 scrub — Juno Ruling 2026-10-28
 * §1.6 Layer 1(1), the exact analogue of the Dart canary gate.
 *
 * A Java [SentryEvent] is seeded with canary values in every B5
 * position (session report §B5: user id = installation ID, device
 * id copy, enriched device context, 35-item permissions map,
 * unscrubbed exception value, mechanism data, non-allowlist tags
 * and contexts), run through [NativeCrashScrub.scrub], and the
 * output is asserted against EVERY row of §1.5, field by field,
 * plus a full-serialization sweep for any surviving canary.
 * Companion tests prove the §1.3 defensive-total property: non-null
 * return and no throw on null/absent-field events, and that Fatal
 * level and a compliant exception type survive.
 */
class NativeCrashScrubTest {

    companion object {
        // The installation-ID position canaries: one UUID-shaped
        // value appearing, as in B5, as user.id, device.id, and a
        // tag value.
        private const val CANARY_INSTALL_ID = "7f3a9c1e-4b2d-4e5f-9a8b-1c2d3e4f5a6b"
        private const val CANARY_EMAIL = "canary-email-7f3a@example.com"
        private const val CANARY_VALUE = "canary exception value with CanaryMedication 42mg"
        private const val CANARY_DEVICE_NAME = "canary-device-name-pixel"
        private const val CANARY_MODEL_ID = "canary-model-id-AP3A"
        private const val CANARY_CHIPSET = "canary-chipset-tensor"
        private const val CANARY_LOCALE = "canary-locale-enUS"
        private const val CANARY_APP_ID = "canary-app-identifier-com.example"
        private const val CANARY_PERMISSION_VALUE = "canary-permission-granted"
        private const val CANARY_KERNEL = "canary-kernel-6.1"
        private const val CANARY_MECHANISM_DATA = "canary-mechanism-data-value"
        private const val CANARY_FRAME_VAR = "canary-frame-var-value"
        private const val CANARY_ABS_PATH = "/data/user/canary-account/seeded.dart"
        private const val CANARY_CONTEXT_LINE = "canary source context line"
        private const val CANARY_CUSTOM_CONTEXT = "canary-healthvalue-231"
        private const val CANARY_GPU = "canary-gpu-name"
        private const val CANARY_FINGERPRINT = "canary-fingerprint-value"
        private const val CANARY_SERVER = "canary-server-name"
        private const val CANARY_RUNTIME_VERSION = "canary-runtime-version-text"
        private const val CANARY_TOP_MODULE = "canary-top-module-1.0"
        private const val CANARY_THREAD_NAME = "canary-thread-name-main"

        private val ALL_CANARIES = listOf(
            CANARY_INSTALL_ID,
            CANARY_EMAIL,
            CANARY_VALUE,
            CANARY_DEVICE_NAME,
            CANARY_MODEL_ID,
            CANARY_CHIPSET,
            CANARY_LOCALE,
            CANARY_APP_ID,
            CANARY_PERMISSION_VALUE,
            CANARY_KERNEL,
            CANARY_MECHANISM_DATA,
            CANARY_FRAME_VAR,
            CANARY_ABS_PATH,
            CANARY_CONTEXT_LINE,
            CANARY_CUSTOM_CONTEXT,
            CANARY_GPU,
            CANARY_FINGERPRINT,
            CANARY_SERVER,
            CANARY_RUNTIME_VERSION,
            CANARY_TOP_MODULE,
            CANARY_THREAD_NAME,
            "canaryTopModule"
        )
    }

    private fun seededB5Event(): SentryEvent {
        val event = SentryEvent()
        event.setLevel(SentryLevel.FATAL)
        event.setPlatform("java")
        event.setRelease("tabs_lab@1.0.0+1")
        event.setDist("2001")
        event.setEnvironment("lab")
        event.setServerName(CANARY_SERVER)
        event.setFingerprints(listOf(CANARY_FINGERPRINT))
        event.setTransaction("canary-transaction")
        event.setLogger("canary-logger")

        // user: installation ID + email + geo (B5 position 1).
        val user = User()
        user.setId(CANARY_INSTALL_ID)
        user.setEmail(CANARY_EMAIL)
        user.setIpAddress("192.0.2.10")
        val geo = Geo()
        geo.setCity("Orem")
        geo.setCountryCode("US")
        geo.setRegion("Utah")
        user.setGeo(geo)
        event.setUser(user)

        val request = Request()
        request.setUrl("https://example.com/path?canary-query=secret99")
        event.setRequest(request)
        event.setBreadcrumbs(listOf(Breadcrumb("canary breadcrumb")))
        event.setExtras(mapOf("note" to CANARY_VALUE))
        event.setModules(mapOf("canaryTopModule" to CANARY_TOP_MODULE))
        val message = Message()
        message.setMessage("canary log message %s")
        event.setMessage(message)
        event.setTags(
            linkedMapOf(
                "release" to "tabs_lab@1.0.0+1",
                "environment" to "lab",
                "event.origin" to "android",
                "event.environment" to "java",
                "isSideLoaded" to "false",
                "installerStore" to "com.android.vending",
                "canaryTag" to CANARY_INSTALL_ID
            )
        )

        // Exception 1: non-identifier type, canary value, canary
        // mechanism data, canary frame positions.
        val frame = SentryStackFrame()
        frame.setModule("com.example.CanaryClass")
        frame.setFunction("canaryMethod")
        frame.setFilename("CanaryClass.java")
        frame.setLineno(42)
        frame.setColno(7)
        frame.setInApp(true)
        frame.setAbsPath(CANARY_ABS_PATH)
        frame.setContextLine(CANARY_CONTEXT_LINE)
        frame.setPreContext(listOf(CANARY_CONTEXT_LINE))
        frame.setPostContext(listOf(CANARY_CONTEXT_LINE))
        frame.setVars(mapOf("seed" to CANARY_FRAME_VAR))
        val trace = SentryStackTrace()
        trace.setFrames(listOf(frame))
        trace.setRegisters(mapOf("pc" to CANARY_FRAME_VAR))

        val mechanism = Mechanism()
        mechanism.setType("generic")
        mechanism.setHandled(false)
        mechanism.setSynthetic(false)
        mechanism.setExceptionGroup(false)
        mechanism.setExceptionId(3)
        mechanism.setParentId(1)
        mechanism.setDescription(CANARY_MECHANISM_DATA)
        mechanism.setHelpLink("https://example.com/canary-help")
        mechanism.setData(mapOf("seed_detail" to CANARY_MECHANISM_DATA))
        mechanism.setMeta(mapOf("signal" to CANARY_MECHANISM_DATA))

        val ex1 = SentryException()
        ex1.setType("SeededException $CANARY_EMAIL")
        ex1.setValue(CANARY_VALUE)
        ex1.setModule("canary.module")
        ex1.setThreadId(9L)
        ex1.setStacktrace(trace)
        ex1.setMechanism(mechanism)

        // Exception 2: compliant type must pass through as-is.
        val ex2 = SentryException()
        ex2.setType("RuntimeException")
        ex2.setValue(CANARY_VALUE)

        event.setExceptions(listOf(ex1, ex2))

        // Thread canary (Vera C1): a native event entering the
        // scrub carries a thread — named with a canary, crashed,
        // holding the canary stack trace — matching ex1's
        // threadId (9), exactly as a real native crash event
        // would. The serialization sweep below must prove the
        // scrubbed event carries no "threads" key on the wire.
        val thread = SentryThread()
        thread.setId(9L)
        thread.setName(CANARY_THREAD_NAME)
        thread.setCrashed(true)
        thread.setCurrent(true)
        thread.setStacktrace(trace)
        event.setThreads(listOf(thread))

        // Contexts: the full B5 enrichment.
        val contexts: Contexts = event.getContexts()
        val app = App()
        app.setAppName("Tabs Lab")
        app.setAppVersion("1.0.0")
        app.setAppBuild("2001")
        app.setAppIdentifier(CANARY_APP_ID)
        app.setAppStartTime(Date(1700000000000L))
        app.setInForeground(true)
        app.setPermissions(
            mapOf(
                "INTERNET" to CANARY_PERMISSION_VALUE,
                "READ_HEART_RATE" to "granted",
                "READ_SLEEP" to "not_granted"
            )
        )
        contexts.setApp(app)

        val device = Device()
        device.setFamily("Pixel")
        device.setModel("Pixel 9a")
        device.setManufacturer("Google")
        device.setArchs(arrayOf("arm64-v8a"))
        device.setId(CANARY_INSTALL_ID)
        device.setName(CANARY_DEVICE_NAME)
        device.setBrand("google")
        device.setModelId(CANARY_MODEL_ID)
        device.setChipset(CANARY_CHIPSET)
        device.setOrientation(Device.DeviceOrientation.PORTRAIT)
        device.setSimulator(false)
        device.setScreenWidthPixels(1080)
        device.setScreenHeightPixels(2424)
        device.setScreenDensity(2.625f)
        device.setScreenDpi(420)
        device.setMemorySize(12000000000L)
        device.setFreeMemory(3000000000L)
        device.setUsableMemory(11000000000L)
        device.setLowMemory(false)
        device.setStorageSize(128000000000L)
        device.setFreeStorage(64000000000L)
        device.setExternalStorageSize(128000000000L)
        device.setExternalFreeStorage(64000000000L)
        device.setBatteryLevel(0.87f)
        device.setBatteryTemperature(31.5f)
        device.setCharging(false)
        device.setTimezone(TimeZone.getTimeZone("America/Denver"))
        device.setLocale(CANARY_LOCALE)
        device.setBootTime(Date(1700000000000L))
        device.setProcessorCount(8)
        device.setProcessorFrequency(2800.0)
        device.setConnectionType("wifi")
        device.setOnline(true)
        contexts.setDevice(device)

        val os = OperatingSystem()
        os.setName("Android")
        os.setVersion("16")
        os.setBuild(CANARY_MODEL_ID)
        os.setKernelVersion(CANARY_KERNEL)
        os.setRooted(false)
        os.setRawDescription(CANARY_KERNEL)
        contexts.setOperatingSystem(os)

        // A Java runtime entry is NOT whitelisted (§1.5): dropped.
        val runtime = SentryRuntime()
        runtime.setName("AndroidRuntime")
        runtime.setVersion(CANARY_RUNTIME_VERSION)
        contexts.setRuntime(runtime)

        val gpu = Gpu()
        gpu.setName(CANARY_GPU)
        contexts.setGpu(gpu)
        contexts.set("health", mapOf("reading" to CANARY_CUSTOM_CONTEXT))
        return event
    }

    @Test
    fun scrubbedEventSatisfiesEverySection15Row() {
        val event = seededB5Event()
        val eventIdBefore = event.getEventId()

        // Vera C1 sanity: the SEEDED event really carries the
        // thread on the wire — the same serializer writes a
        // "threads" key and the canary thread name before the
        // scrub. Without this, the post-scrub absence assertion
        // below could pass vacuously.
        val seededWriter = StringWriter()
        JsonSerializer(SentryOptions()).serialize(event, seededWriter)
        val seededJson = seededWriter.toString()
        assertTrue(seededJson.contains("\"threads\""))
        assertTrue(seededJson.contains(CANARY_THREAD_NAME))
        val seededThreads = event.getThreads()
        assertTrue(seededThreads != null && seededThreads.isNotEmpty())

        val result = NativeCrashScrub.scrub(event)

        // Never null, same event (§1.3).
        assertNotNull(result)
        assertSame(event, result)

        // ── Top-level absent rows ──
        assertNull(result.getUser())
        assertNull(result.getRequest())
        val crumbs = result.getBreadcrumbs()
        assertTrue(crumbs == null || crumbs.isEmpty())
        val extrasAfter = result.getExtras()
        assertTrue(extrasAfter == null || extrasAfter.isEmpty())
        // (getModules() is package-private in the SDK; the modules
        // row is proven by the serialization sweep below.)
        assertNull(result.getMessage())
        assertNull(result.getServerName())
        assertNull(result.getFingerprints())
        // SentryEvent.setThreads(null) stores an EMPTY SentryValues in
        // sentry-java 8.61.1 (never null); object-level the scrubbed
        // event is null-or-empty here, and the serialization sweep
        // below proves the wire side: the seeded thread canary is
        // gone and no "threads" key is written (Vera C1).
        val threadsAfter = result.getThreads()
        assertTrue(threadsAfter == null || threadsAfter.isEmpty())
        assertNull(result.getTransaction())
        assertNull(result.getLogger())
        assertNull(result.getUnknown())

        // ── Permitted envelope fields survive ──
        assertEquals(eventIdBefore, result.getEventId())
        assertEquals(SentryLevel.FATAL, result.getLevel())
        assertEquals("java", result.getPlatform())
        assertEquals("tabs_lab@1.0.0+1", result.getRelease())
        assertEquals("2001", result.getDist())
        assertEquals("lab", result.getEnvironment())

        // ── Tags: subset of {release, environment} ──
        val tags = result.getTags()
        assertNotNull(tags)
        assertEquals(setOf("release", "environment"), tags!!.keys)
        assertEquals("tabs_lab@1.0.0+1", tags["release"])
        assertEquals("lab", tags["environment"])

        // ── Exception rows ──
        val exceptions = result.getExceptions()
        assertNotNull(exceptions)
        assertEquals(2, exceptions!!.size)
        assertEquals("ScrubbedExceptionType", exceptions[0].getType())
        assertEquals(
            NativeCrashScrub.SCRUBBED_EXCEPTION_VALUE, exceptions[0].getValue()
        )
        assertEquals(
            "[scrubbed: exception value withheld — type and stack trace only]",
            exceptions[0].getValue()
        )
        assertEquals("RuntimeException", exceptions[1].getType())
        assertEquals(
            NativeCrashScrub.SCRUBBED_EXCEPTION_VALUE, exceptions[1].getValue()
        )
        assertEquals("canary.module", exceptions[0].getModule())
        assertEquals(9L, exceptions[0].getThreadId())

        // ── Mechanism row: code-shaped fields only, data gone ──
        val mechanism = exceptions[0].getMechanism()
        assertNotNull(mechanism)
        assertEquals("generic", mechanism!!.getType())
        assertEquals(false, mechanism.isHandled())
        assertEquals(false, mechanism.getSynthetic())
        assertEquals(false, mechanism.isExceptionGroup())
        assertEquals(3, mechanism.getExceptionId())
        assertEquals(1, mechanism.getParentId())
        val mechData = mechanism.getData()
        val mechMeta = mechanism.getMeta()
        assertTrue(mechData == null || mechData.isEmpty())
        assertTrue(mechMeta == null || mechMeta.isEmpty())
        assertNull(mechanism.getDescription())
        assertNull(mechanism.getHelpLink())

        // ── Frame row: code identifiers only ──
        val frames = exceptions[0].getStacktrace()!!.getFrames()
        assertNotNull(frames)
        assertEquals(1, frames!!.size)
        val frame = frames[0]
        assertEquals("com.example.CanaryClass", frame.getModule())
        assertEquals("canaryMethod", frame.getFunction())
        assertEquals("CanaryClass.java", frame.getFilename())
        assertEquals(42, frame.getLineno())
        assertEquals(7, frame.getColno())
        assertEquals(true, frame.isInApp())
        assertNull(frame.getAbsPath())
        assertNull(frame.getContextLine())
        assertNull(frame.getPreContext())
        assertNull(frame.getPostContext())
        val frameVars = frame.getVars()
        assertTrue(frameVars == null || frameVars.isEmpty())
        assertNull(exceptions[0].getStacktrace()!!.getRegisters())

        // ── Context rows ──
        val contexts = result.getContexts()
        val keys = HashSet<String>()
        val keyEnum = contexts.keys()
        while (keyEnum.hasMoreElements()) keys.add(keyEnum.nextElement())
        assertEquals(setOf("app", "device", "os"), keys)

        val app = contexts.getApp()
        assertNotNull(app)
        assertEquals("Tabs Lab", app!!.getAppName())
        assertEquals("1.0.0", app.getAppVersion())
        assertEquals("2001", app.getAppBuild())
        assertNull(app.getPermissions())
        assertNull(app.getAppIdentifier())
        assertNull(app.getAppStartTime())
        assertNull(app.getInForeground())
        assertNull(app.getDeviceAppHash())
        assertNull(app.getBuildType())
        assertNull(app.getViewNames())
        assertNull(app.getUnknown())

        val device = contexts.getDevice()
        assertNotNull(device)
        assertEquals("Pixel", device!!.getFamily())
        assertEquals("Pixel 9a", device.getModel())
        assertEquals("Google", device.getManufacturer())
        assertEquals(listOf("arm64-v8a"), device.getArchs()!!.toList())
        assertNull(device.getId())
        assertNull(device.getName())
        assertNull(device.getBrand())
        assertNull(device.getModelId())
        assertNull(device.getChipset())
        assertNull(device.getOrientation())
        assertNull(device.isSimulator())
        assertNull(device.getScreenWidthPixels())
        assertNull(device.getScreenHeightPixels())
        assertNull(device.getScreenDensity())
        assertNull(device.getScreenDpi())
        assertNull(device.getMemorySize())
        assertNull(device.getFreeMemory())
        assertNull(device.getUsableMemory())
        assertNull(device.getStorageSize())
        assertNull(device.getFreeStorage())
        assertNull(device.getExternalStorageSize())
        assertNull(device.getExternalFreeStorage())
        assertNull(device.getBatteryLevel())
        assertNull(device.getBatteryTemperature())
        assertNull(device.isCharging())
        assertNull(device.getTimezone())
        assertNull(device.getLocale())
        assertNull(device.getBootTime())
        assertNull(device.getProcessorCount())
        assertNull(device.getProcessorFrequency())
        assertNull(device.getConnectionType())
        assertNull(device.isOnline())
        assertNull(device.isLowMemory())
        assertNull(device.getUnknown())

        val os = contexts.getOperatingSystem()
        assertNotNull(os)
        assertEquals("Android", os!!.getName())
        assertEquals("16", os.getVersion())
        assertNull(os.getBuild())
        assertNull(os.getKernelVersion())
        assertNull(os.isRooted())
        assertNull(os.getRawDescription())

        // Java runtime dropped whole; gpu + custom contexts absent.
        assertNull(contexts.getRuntime())
        assertNull(contexts.getGpu())
        assertNull(contexts.getTrace())
        assertFalse(contexts.containsKey("health"))

        // ── Full-serialization canary sweep ──
        val writer = StringWriter()
        JsonSerializer(SentryOptions()).serialize(result, writer)
        val json = writer.toString()
        for (canary in ALL_CANARIES) {
            assertFalse("canary survived serialization: $canary", json.contains(canary))
        }
        assertFalse(json.contains("\"user\""))
        assertFalse(json.contains("\"permissions\""))
        assertFalse(json.contains("\"modules\""))
        assertFalse(json.contains("\"breadcrumbs\""))
        assertFalse(json.contains("\"request\""))
        assertFalse(json.contains("\"extra\""))
        // Vera C1: a thread was seeded into this event (see the
        // pre-scrub sanity above), so this assertion proves the
        // "threads" key's absence on the wire, not vacuously.
        assertFalse(json.contains("\"threads\""))
        assertTrue(json.contains("RuntimeException"))
        assertTrue(json.contains("Pixel 9a"))
    }

    @Test
    fun runtimeRuleWhitelistDartAndFlutterOnly() {
        fun eventWithRuntime(name: String, version: String?): SentryEvent {
            val e = SentryEvent()
            val rt = SentryRuntime()
            rt.setName(name)
            rt.setVersion(version)
            e.getContexts().setRuntime(rt)
            return e
        }

        val dart = NativeCrashScrub.scrub(eventWithRuntime("Dart", "3.13.5"))
        assertEquals("Dart", dart.getContexts().getRuntime()!!.getName())
        assertEquals("3.13.5", dart.getContexts().getRuntime()!!.getVersion())

        val flutterBadVersion =
            NativeCrashScrub.scrub(eventWithRuntime("Flutter", CANARY_RUNTIME_VERSION))
        assertEquals("Flutter", flutterBadVersion.getContexts().getRuntime()!!.getName())
        assertNull(flutterBadVersion.getContexts().getRuntime()!!.getVersion())

        val java = NativeCrashScrub.scrub(eventWithRuntime("AndroidRuntime", "2.1"))
        assertNull(java.getContexts().getRuntime())
    }

    @Test
    fun scrubIsTotalOnNullAndAbsentFields() {
        // Bare event: null user/contexts content/exception/tags.
        val bare = SentryEvent()
        val out = NativeCrashScrub.scrub(bare)
        assertNotNull(out)
        assertSame(bare, out)
        assertNull(out.getUser())
        assertNull(out.getExceptions())

        // Exceptions present but every sub-field null.
        val sparse = SentryEvent()
        sparse.setLevel(SentryLevel.FATAL)
        val ex = SentryException()
        sparse.setExceptions(listOf(ex))
        val out2 = NativeCrashScrub.scrub(sparse)
        assertEquals(SentryLevel.FATAL, out2.getLevel())
        val scrubbedEx = out2.getExceptions()!!.single()
        assertEquals("ScrubbedExceptionType", scrubbedEx.getType())
        assertEquals(
            NativeCrashScrub.SCRUBBED_EXCEPTION_VALUE, scrubbedEx.getValue()
        )
        assertNull(scrubbedEx.getStacktrace())
        assertNull(scrubbedEx.getMechanism())
    }

    @Test
    fun exceptionTypeSanitiserMatchesDartRule() {
        assertEquals(
            "RuntimeException",
            NativeCrashScrub.sanitizeExceptionType("RuntimeException")
        )
        assertEquals(
            "com.example.Outer\$Inner",
            NativeCrashScrub.sanitizeExceptionType("com.example.Outer\$Inner")
        )
        assertEquals(
            "ScrubbedExceptionType",
            NativeCrashScrub.sanitizeExceptionType("Exception $CANARY_EMAIL")
        )
        assertEquals(
            "ScrubbedExceptionType", NativeCrashScrub.sanitizeExceptionType("")
        )
        assertEquals(
            "ScrubbedExceptionType", NativeCrashScrub.sanitizeExceptionType(null)
        )
        assertEquals(
            "ScrubbedExceptionType",
            NativeCrashScrub.sanitizeExceptionType("a".repeat(129))
        )
    }
}
