plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.hilt.android)
    alias(libs.plugins.ksp)
}

// ---- Tabs Play Store release signing ----
// Credentials come from Gradle properties OUTSIDE source control
// (e.g. ~/.gradle/gradle.properties). Nothing secret is stored in this repo.
// Expected properties:
//   tabsUpload.storeFile      absolute path to the upload keystore
//   tabsUpload.storePassword  keystore password
//   tabsUpload.keyAlias       key alias (default: tabs-upload)
//   tabsUpload.keyPassword    key password (for this PKCS12 keystore it must
//                             equal the store password - verified 2026-09-29)
// If the properties are absent, release builds keep their previous behavior
// (Gradle signs them with the debug key), so machines without secrets still
// build. Such an AAB will be rejected by Play (wrong upload-key fingerprint).
val tabsUploadStoreFile: String? = findProperty("tabsUpload.storeFile") as String?
val tabsUploadStorePassword: String? = findProperty("tabsUpload.storePassword") as String?
val tabsUploadKeyAlias: String = (findProperty("tabsUpload.keyAlias") as String?) ?: "tabs-upload"
val tabsUploadKeyPassword: String? = findProperty("tabsUpload.keyPassword") as String?
val hasTabsUploadSigning = !tabsUploadStoreFile.isNullOrBlank()
    && !tabsUploadStorePassword.isNullOrBlank()
    && !tabsUploadKeyPassword.isNullOrBlank()

// ---- CI versionCode override (Play release pipeline) ----
// Google Play rejects any upload whose versionCode is not higher than the
// last one. The GitHub Actions workflow passes -PversionCodeOverride=<int>
// (10000 + the CI run number) so every automated upload is unique and
// increasing. Local builds without the property keep versionCode 15.
val versionCodeOverride: Int? = (findProperty("versionCodeOverride") as String?)?.toIntOrNull()

// ---- Playground ("Tabs Lab") experimental build ----
// Active ONLY when invoked with -PtabsPlayground=true. The playground CI
// job passes it; main-branch builds never do. It makes the Lab build
// install as a fully separate app from production Tabs — applicationId
// com.notel.notel.playground with its own data, the "Tabs Lab" label, and
// a tinted launcher icon — so experiments can never touch production
// data. The release signing config above is untouched, and the playground
// CI job only ever builds a debug APK.
val isPlaygroundBuild = (findProperty("tabsPlayground") as String?)?.toBoolean() == true

android {
    namespace = "com.notel.notel"
    compileSdk = 36

    if (!hasTabsUploadSigning) {
        logger.warn("tabsUpload.* signing properties not set - release builds will be signed with the debug key and WILL be rejected by Google Play.")
    }

    defaultConfig {
        applicationId = "com.notel.notel"
        minSdk = 26
        targetSdk = 36
        versionCode = versionCodeOverride ?: 15
        versionName = "2.3"

        if (isPlaygroundBuild) {
            // Separate app from production Tabs: own package, own data.
            applicationIdSuffix = ".playground"
            // resValue wins over the XML resource of the same name.
            resValue("string", "app_name", "Tabs Lab")
            // Deep-teal adaptive-icon background matching the tinted Lab icon.
            resValue("color", "tabs_icon_background", "#0B3B2E")
        }

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        
        ksp {
            arg("room.schemaLocation", "$projectDir/schemas")
        }
    }

    signingConfigs {
        create("sharedDebug") {
            storeFile = file("../shared-debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        if (hasTabsUploadSigning) {
            create("tabsUpload") {
                storeFile = file(tabsUploadStoreFile!!)
                storePassword = tabsUploadStorePassword
                keyAlias = tabsUploadKeyAlias
                keyPassword = tabsUploadKeyPassword
            }
        }
    }

    buildTypes {
        getByName("debug") {
            signingConfig = signingConfigs.getByName("sharedDebug")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (hasTabsUploadSigning) {
                signingConfig = signingConfigs.getByName("tabsUpload")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }
    buildFeatures {
        compose = true
    }

    sourceSets {
        getByName("androidTest") {
            assets.srcDir("$projectDir/schemas")
        }
        if (isPlaygroundBuild) {
            // The debug source set overlays main (documented resource-merger
            // behavior), so the tinted ic_tabs_launcher.png here replaces
            // the production icon for Lab builds only. Same-name files in
            // two srcDirs of ONE source set are a duplicate-resource build
            // error, which is why this lives on the debug source set.
            getByName("debug") {
                res.srcDir("playground-res")
            }
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.coil.compose)

    // Room
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)

    // Hilt
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.hilt.navigation.compose)
    implementation(libs.hilt.work)
    ksp(libs.hilt.compiler.androidx)

    // OkHttp & Retrofit (API)
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging)
    implementation(libs.retrofit)
    implementation(libs.retrofit.converter.kotlinx.serialization)

    // Kotlin Serialization
    implementation(libs.kotlinx.serialization.json)

    // Coroutines
    implementation(libs.kotlinx.coroutines.android)

    // DataStore (settings/API key)
    implementation(libs.androidx.datastore.preferences)

    // Health Connect
    implementation(libs.androidx.health.connect)

    // Play Billing
    implementation(libs.google.billing)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.core.google.shortcuts)

    // Location
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("com.google.android.gms:play-services-auth:21.2.0")

    // Jetpack Glance (home screen widget)
    implementation("androidx.glance:glance-appwidget:1.1.1")
    implementation("androidx.glance:glance-material3:1.1.1")

    // Tests
    testImplementation(libs.junit)
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.1")
    testImplementation("org.mockito:mockito-core:5.14.2")
    testImplementation("org.mockito.kotlin:mockito-kotlin:5.4.0")
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.room.testing)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}