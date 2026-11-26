import java.io.File
import java.io.FileInputStream
import java.util.Properties
plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- Tabs production upload signing (TAKEOVER Phase 1) ----
// Mirrors the native app's proven pattern (app/build.gradle.kts on main):
// credentials come from Gradle properties OUTSIDE source control
// (CI secrets -> runner-local gradle.properties, or a developer's
// ~/.gradle/gradle.properties). Nothing secret is stored in this repo.
// Expected properties:
//   tabsUpload.storeFile      absolute path to the upload keystore
//   tabsUpload.storePassword  keystore password
//   tabsUpload.keyAlias       key alias (default: tabs-upload)
//   tabsUpload.keyPassword    key password (default: the store password —
//                             for this PKCS12 keystore the private key is
//                             protected by the store password, verified
//                             2026-09-29 on the native pipeline; the CI
//                             workflow passes keyPassword == storePassword)
val tabsUploadStoreFile: String? = findProperty("tabsUpload.storeFile") as String?
val tabsUploadStorePassword: String? = findProperty("tabsUpload.storePassword") as String?
val tabsUploadKeyAlias: String = (findProperty("tabsUpload.keyAlias") as String?) ?: "tabs-upload"
val tabsUploadKeyPassword: String? =
    (findProperty("tabsUpload.keyPassword") as String?) ?: tabsUploadStorePassword
val hasTabsUploadSigning = !tabsUploadStoreFile.isNullOrBlank()
    && !tabsUploadStorePassword.isNullOrBlank()
    && !tabsUploadKeyPassword.isNullOrBlank()

if (!hasTabsUploadSigning) {
    logger.warn(
        "tabsUpload.* signing properties not set — the prod flavor cannot " +
            "be signed for Play. Lab builds are unaffected; production " +
            "bundle/APK tasks will FAIL (see the fail-closed guard below)."
    )
}

// ---- Production version-code floor (TAKEOVER Phase 1) ----
// Highest versionCode on Play for com.notel.notel is 10091 (closed
// track, established in Phase 0 / Harbor's check). A production AAB at
// or below that can never be uploaded, so 10092 is the permanent
// minimum for a prod build. The CI workflow supplies the real code
// per build via `flutter build appbundle --build-number=<code>`;
// without that parameter flutter.versionCode falls back to the
// pubspec value (1) and the guard below fails the build closed.
val minProdVersionCode = 10092

// ---- Tabs Lab Play upload signing + version code (Lab Play prep) ----
// The `labplay` flavor is the SAME Lab identity as `lab`
// (applicationId com.notel.notel.playground.flutter, label "Tabs Lab")
// signed for Play with a DEDICATED Lab upload key — never the
// production tabsUpload key and never the committed debug keystore.
// Credentials come from a properties file OUTSIDE source control:
//   ~/workspace/tabs-lab-signing/lab-signing.properties
// (override the location with the Gradle property
// labPlay.signingPropertiesFile). Expected keys in that file:
//   storeFile      path to tabs-lab-upload.jks (absolute, or relative
//                  to the properties file's own directory)
//   storePassword  keystore password
//   keyAlias       key alias (default: tabs-lab-upload)
//   keyPassword    key password (default: the store password)
// Nothing secret is stored in this repo. When the file is absent the
// labplay signing config stays empty and every labplay bundle/APK
// task FAILS LOUDLY (see the fail-closed guard at the bottom of this
// file) — it never falls back to debug or any other signing. Lab and
// prod builds are unaffected by the file's absence.
// Default location: ~/workspace/tabs-lab-signing/lab-signing.properties,
// resolved from the HOME environment variable first — on machines
// where the build runs as a different user than the workspace owner,
// java's user.home does NOT point at the workspace home, so it is
// only a fallback candidate. The first existing candidate wins; if
// none exists, the HOME-based candidate is the path named in the
// fail-closed guard's error.
val labPlaySigningCandidates: List<java.io.File> =
    listOfNotNull(
        System.getenv("HOME"),
        System.getProperty("user.home")
    ).distinct().map {
        File(it, "workspace/tabs-lab-signing/lab-signing.properties")
    }
val labPlaySigningPropertiesFile: java.io.File =
    (findProperty("labPlay.signingPropertiesFile") as String?)
        ?.takeIf { it.isNotBlank() }
        ?.let { File(it) }
        ?: labPlaySigningCandidates.firstOrNull { it.isFile }
        ?: labPlaySigningCandidates.first()
val labPlaySigningProperties = Properties()
var labPlaySigningPropertiesLoaded = false
if (labPlaySigningPropertiesFile.isFile) {
    FileInputStream(labPlaySigningPropertiesFile).use {
        labPlaySigningProperties.load(it)
    }
    labPlaySigningPropertiesLoaded = true
}
val labPlayStoreFileRaw: String? =
    labPlaySigningProperties.getProperty("storeFile")?.takeIf { it.isNotBlank() }
val labPlayStoreFile: java.io.File? = labPlayStoreFileRaw?.let { raw ->
    val candidate = File(raw)
    if (candidate.isAbsolute) candidate
    else File(labPlaySigningPropertiesFile.parentFile, raw)
}
val labPlayStorePassword: String? =
    labPlaySigningProperties.getProperty("storePassword")?.takeIf { it.isNotBlank() }
val labPlayKeyAlias: String =
    labPlaySigningProperties.getProperty("keyAlias")?.takeIf { it.isNotBlank() }
        ?: "tabs-lab-upload"
val labPlayKeyPassword: String? =
    labPlaySigningProperties.getProperty("keyPassword")?.takeIf { it.isNotBlank() }
        ?: labPlayStorePassword
val hasLabPlaySigning = labPlaySigningPropertiesLoaded
    && labPlayStoreFile != null
    && !labPlayStorePassword.isNullOrBlank()
    && !labPlayKeyPassword.isNullOrBlank()

if (!hasLabPlaySigning) {
    logger.warn(
        "Lab Play signing properties not loaded from " +
            "${labPlaySigningPropertiesFile.absolutePath} — the labplay " +
            "flavor cannot be signed for Play. Lab and prod builds are " +
            "unaffected; labplay bundle/APK tasks will FAIL (see the " +
            "fail-closed guard below)."
    )
}

// ---- Lab Play version-code channel (Lab Play prep) ----
// The Lab package identity has version-code history separate from
// production's 100xxx sequence and from the pubspec code (1) that
// ordinary local Lab APKs carry. The highest Lab code verified on a
// built artifact for com.notel.notel.playground.flutter is 2001
// (aapt2 badging on the Oct 28, 2026 Phase 3 evidence APK,
// 1.0.0 / VC 2001, built with an ad hoc --build-number; Bram's
// architecture review confirmed this as the primary VC evidence).
// Play Lab starts in its own 3001+ band so a Play code can never be
// confused at a glance with a sideload Lab code (<= 2001) or with a
// production code (100xxx). The first Play Lab code is therefore
// 3001, and 3001 is the floor. Every Play Lab build supplies its
// code explicitly with `flutter build appbundle --flavor labplay
// --build-number=<code>`; an explicit in-band --build-number is
// honored here. The Gradle property labPlay.versionCode (for CI:
// ORG_GRADLE_PROJECT_labPlay.versionCode) or the
// LABPLAY_VERSION_CODE environment variable may override the
// build-number channel. Only the labplay flavor reads these values;
// with no labPlay build in flight, lab and prod keep exactly their
// current version behavior.
val minLabPlayVersionCode = 3001
val defaultLabPlayVersionCode = 3001
val labPlayVersionCodeRaw: String? =
    (findProperty("labPlay.versionCode") as String?)
        ?: System.getenv("LABPLAY_VERSION_CODE")
val labPlayVersionCode: Int =
    labPlayVersionCodeRaw?.toIntOrNull()
        ?: if (flutter.versionCode == 1) defaultLabPlayVersionCode
        else flutter.versionCode

android {
    namespace = "com.notel.notel.playground.flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Round 30: flutter_local_notifications requires core library
        // desugaring for scheduled notifications on older Android
        // versions (plugin setup docs).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Default identity is the Lab identity; the `prod` flavor below
        // overrides applicationId/label/signing for production. The
        // namespace (and therefore the Kotlin package, MethodChannel
        // names, widget class and proguard keeps) deliberately does NOT
        // change per flavor — flavors change applicationId only.
        applicationId = "com.notel.notel.playground.flutter"
        // Round 12: minSdk 26 — required by the Health Connect client
        // (matches the native app's minSdk).
        multiDexEnabled = true
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // App label, consumed as ${appLabel} by the main manifest.
        // Default is the Lab label; the prod flavor overrides it.
        manifestPlaceholders["appLabel"] = "Tabs Lab"
    }

    signingConfigs {
        getByName("debug") {
            // Committed debug keystore (same as the original tabs-flutter-lab repo)
            // so release builds keep signature continuity with the Flutter Lab
            // builds already installed on the founder's Pixel.
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        // Always created so the prod flavor can reference it. When the
        // tabsUpload.* properties are absent its fields stay empty and
        // any attempt to sign a prod variant with it fails — the prod
        // flavor NEVER falls back to the debug (Lab) signing config.
        create("tabsUpload") {
            storeFile = tabsUploadStoreFile?.let { file(it) }
            storePassword = tabsUploadStorePassword
            keyAlias = tabsUploadKeyAlias
            keyPassword = tabsUploadKeyPassword
        }
        // Always created so the labplay flavor can reference it. When
        // the Lab Play properties file is absent its fields stay empty
        // and any attempt to sign a labplay variant with it fails —
        // the labplay flavor NEVER falls back to the debug (local
        // Lab) signing config or to the production tabsUpload config.
        create("tabsLabUpload") {
            storeFile = labPlayStoreFile
            storePassword = labPlayStorePassword
            keyAlias = labPlayKeyAlias
            keyPassword = labPlayKeyPassword
        }
    }

    flavorDimensions += "identity"

    productFlavors {
        // Lab FIRST: it is the default flavor, so every existing Lab
        // build command and workflow keeps producing exactly today's
        // identity (applicationId com.notel.notel.playground.flutter,
        // label "Tabs Lab", committed debug-keystore signing).
        create("lab") {
            dimension = "identity"
            applicationId = "com.notel.notel.playground.flutter"
            manifestPlaceholders["appLabel"] = "Tabs Lab"
            signingConfig = signingConfigs.getByName("debug")
        }
        // Lab Play: the Lab identity packaged for Play. SAME
        // applicationId and label as `lab`; the only differences are
        // the signing config (the dedicated Lab upload key above,
        // never the debug keystore) and the versionCode, which comes
        // from the Lab Play channel (an explicit --build-number, or
        // labPlay.versionCode / LABPLAY_VERSION_CODE, default 3001)
        // instead of the pubspec code. versionName still inherits
        // flutter.versionName from defaultConfig, exactly as `lab` does.
        create("labplay") {
            dimension = "identity"
            applicationId = "com.notel.notel.playground.flutter"
            manifestPlaceholders["appLabel"] = "Tabs Lab"
            signingConfig = signingConfigs.getByName("tabsLabUpload")
            versionCode = labPlayVersionCode
        }
        // Production: the native app's package and label, signed with
        // the Play upload key. See the fail-closed guard at the bottom
        // of this file — bundleProd*/assembleProd* tasks refuse to run
        // without the signing properties and a versionCode >=
        // minProdVersionCode.
        create("prod") {
            dimension = "identity"
            applicationId = "com.notel.notel"
            manifestPlaceholders["appLabel"] = "Tabs"
            signingConfig = signingConfigs.getByName("tabsUpload")
        }
    }

    buildTypes {
        release {
            // Signing is assigned per flavor above (lab -> debug
            // keystore, prod -> tabsUpload). Intentionally NO
            // signingConfig in this block: a build-type signing config
            // would apply to every flavor's release variant and could
            // silently Lab-sign a production bundle.
            // Round 52: explicit R8 keep rules for the home-screen
            // widget receiver + home_widget classes (see the file —
            // a silently renamed manifest-facing class is the R51
            // regression class). Rules only; minify/shrink settings
            // are unchanged from the Flutter defaults.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

// ---- Production fail-closed guard (TAKEOVER Phase 1) ----
// A misconfigured "production" build must be impossible, never
// silently Lab-signed or built with the pubspec versionCode (1).
// Two layers, same checks, covering BOTH prod output tasks:
// bundleProd* (AAB, `flutter build appbundle --flavor prod`) and
// assembleProd* (APK, `flutter build apk --flavor prod`) — a hand-run
// prod APK gets exactly the same signing + version-floor checks as
// the bundle, so it can never slip out at versionCode 1 unsigned by
// the upload key.
//   1. Configuration time: any Gradle invocation whose requested
//      tasks include a prod bundle or assemble task (e.g.
//      bundleProdRelease / assembleProdRelease) fails immediately
//      when signing properties are missing, the keystore file does
//      not exist, or flutter.versionCode (set by the --build-number
//      parameter) is below the Play floor.
//   2. A verifyProdReleaseConfig task wired as a dependency of every
//      bundleProd*/assembleProd* task, re-checking at execution time.
fun prodConfigProblems(): List<String> {
    val problems = mutableListOf<String>()
    if (!hasTabsUploadSigning) {
        problems += "tabsUpload.* signing properties are missing " +
            "(need tabsUpload.storeFile and tabsUpload.storePassword; " +
            "keyPassword defaults to the store password). Refusing to " +
            "build production output that could not be signed with " +
            "the Play upload key."
    } else {
        val keystore = tabsUploadStoreFile?.let { file(it) }
        if (keystore == null || !keystore.exists()) {
            problems += "tabsUpload.storeFile does not exist: " +
                (tabsUploadStoreFile ?: "<unset>")
        }
    }
    if (flutter.versionCode < minProdVersionCode) {
        problems += "versionCode is ${flutter.versionCode} but a " +
            "production build needs >= $minProdVersionCode (highest " +
            "code on Play is 10091). Pass it as a build parameter: " +
            "flutter build appbundle --flavor prod " +
            "--build-number=<code> --build-name=<name>."
    }
    return problems
}

val requestedTaskNames = gradle.startParameter.taskNames.joinToString(" ").lowercase()
if ("bundleprod" in requestedTaskNames || "assembleprod" in requestedTaskNames) {
    val problems = prodConfigProblems()
    if (problems.isNotEmpty()) {
        throw GradleException(
            "Refusing to build production (bundle/APK):\n - " +
                problems.joinToString("\n - ")
        )
    }
}

val verifyProdReleaseConfig by tasks.registering {
    group = "verification"
    description = "Fails closed if a production build (bundle or APK) " +
        "would be built without upload signing or a Play-valid versionCode."
    doLast {
        val problems = prodConfigProblems()
        if (problems.isNotEmpty()) {
            throw GradleException(
                "Production build configuration check failed:\n - " +
                    problems.joinToString("\n - ")
            )
        }
        logger.lifecycle(
            "Production build config OK: tabsUpload signing present, " +
                "versionCode ${flutter.versionCode} >= $minProdVersionCode."
        )
    }
}

tasks.configureEach {
    if (name.startsWith("bundleProd") || name.startsWith("assembleProd")) {
        dependsOn(verifyProdReleaseConfig)
    }
}

// ---- Lab Play fail-closed guard (Lab Play prep) ----
// Mirrors the production guard above for the labplay flavor: a
// labplay bundle/APK must be impossible to produce without the
// dedicated Lab upload signing, with a versionCode below the
// dedicated Play Lab band (3001+), or with a production-sequence
// code (100xxx). No silent fallback to the debug keystore, the
// production key, or the pubspec code.
//   1. Configuration time: any Gradle invocation whose requested
//      tasks include a labplay bundle or assemble task (e.g.
//      bundleLabplayRelease / assembleLabplayRelease) fails
//      immediately on any problem below.
//   2. A verifyLabPlayReleaseConfig task wired as a dependency of
//      every bundleLabplay*/assembleLabplay* task, re-checking at
//      execution time.
fun labPlayConfigProblems(): List<String> {
    val problems = mutableListOf<String>()
    if (!labPlaySigningPropertiesLoaded) {
        problems += "Lab Play signing properties file not found: " +
            labPlaySigningPropertiesFile.absolutePath + " (expected " +
            "keys storeFile, storePassword, keyAlias, keyPassword). " +
            "Refusing to build Lab Play output that could not be " +
            "signed with the dedicated Lab upload key."
    } else if (!hasLabPlaySigning) {
        problems += "Lab Play signing properties are incomplete in " +
            labPlaySigningPropertiesFile.absolutePath + " (need " +
            "storeFile and storePassword; keyPassword defaults to " +
            "the store password). Refusing to build Lab Play output."
    } else {
        val keystore = labPlayStoreFile
        if (keystore == null || !keystore.exists()) {
            problems += "Lab Play storeFile does not exist: " +
                (labPlayStoreFileRaw ?: "<unset>")
        }
    }
    if (labPlayVersionCodeRaw != null && labPlayVersionCodeRaw.toIntOrNull() == null) {
        problems += "Lab Play versionCode override is not an " +
            "integer: $labPlayVersionCodeRaw (set it via " +
            "--build-number, the labPlay.versionCode Gradle " +
            "property, or the LABPLAY_VERSION_CODE environment " +
            "variable)."
    }
    if (labPlayVersionCode < minLabPlayVersionCode) {
        problems += "Lab Play versionCode is $labPlayVersionCode " +
            "but a Play Lab build needs >= $minLabPlayVersionCode " +
            "(the Play Lab band starts at 3001; the highest " +
            "sideload Lab code already used is 2001). Pass it " +
            "explicitly: flutter build appbundle --flavor " +
            "labplay --build-number=<code>."
    }
    if (labPlayVersionCode >= 100000) {
        problems += "Lab Play versionCode is $labPlayVersionCode, " +
            "which is in the production 100xxx sequence. Play Lab " +
            "codes stay in their own band below 100000."
    }
    return problems
}

if ("bundlelabplay" in requestedTaskNames || "assemblelabplay" in requestedTaskNames) {
    val problems = labPlayConfigProblems()
    if (problems.isNotEmpty()) {
        throw GradleException(
            "Refusing to build Lab Play (bundle/APK):\n - " +
                problems.joinToString("\n - ")
        )
    }
}

val verifyLabPlayReleaseConfig by tasks.registering {
    group = "verification"
    description = "Fails closed if a Lab Play build (bundle or APK) " +
        "would be built without the Lab upload signing or a " +
        "Play-valid Lab versionCode."
    doLast {
        val problems = labPlayConfigProblems()
        if (problems.isNotEmpty()) {
            throw GradleException(
                "Lab Play build configuration check failed:\n - " +
                    problems.joinToString("\n - ")
            )
        }
        logger.lifecycle(
            "Lab Play build config OK: tabsLabUpload signing " +
                "present, versionCode $labPlayVersionCode >= " +
                "$minLabPlayVersionCode."
        )
    }
}

tasks.configureEach {
    if (name.startsWith("bundleLabplay") || name.startsWith("assembleLabplay")) {
        dependsOn(verifyLabPlayReleaseConfig)
    }
}

// Round 12: Health Connect client for the connections screen permission flow.
// Version matches the native app (1.1.0-alpha09). The dependency now
// arrives via the health_connect_bridge plugin (an `api` dependency
// there): the bridge handlers live in the plugin, and MainActivity
// still compiles against PermissionController for the Activity-owned
// permission launcher it registers in onCreate.
dependencies {
    // Round 30: desugaring runtime for flutter_local_notifications.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
