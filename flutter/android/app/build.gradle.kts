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

// Round 12: Health Connect client for the connections screen permission flow.
// Version matches the native app (1.1.0-alpha09). The dependency now
// arrives via the health_connect_bridge plugin (an `api` dependency
// there): the bridge handlers live in the plugin, and MainActivity
// still compiles against PermissionController for the Activity-owned
// permission launcher it registers in onCreate.
dependencies {
    // Round 30: desugaring runtime for flutter_local_notifications.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Phase 3 (Juno Ruling 2026-10-28 §1.6 Layer 1(1)): JVM unit
    // test for the Kotlin native C1 scrub (NativeCrashScrubTest).
    // The io.sentry classes under test arrive on the compile
    // classpath via the sentry_flutter plugin's `api` dependency on
    // sentry-android 8.61.1; only JUnit itself needs declaring.
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
