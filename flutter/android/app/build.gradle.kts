plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
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
    }

    buildTypes {
        release {
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// Round 12: Health Connect client for the connections screen permission flow.
// Version matches the native app (1.1.0-alpha09).
dependencies {
    implementation("androidx.health.connect:connect-client:1.1.0-alpha09")
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
