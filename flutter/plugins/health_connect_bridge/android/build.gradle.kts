group = "com.notel.notel.playground.flutter.health_connect_bridge"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.notel.notel.playground.flutter.health_connect_bridge"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // Health Connect client requires minSdk 26 (team lesson);
        // the app module is also 26.
        minSdk = 26
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Same Health Connect client version the app module used when
    // these handlers lived in MainActivity. `api` because MainActivity
    // still compiles against PermissionController to register the
    // Activity-owned permission launcher in onCreate.
    api("androidx.health.connect:connect-client:1.1.0-alpha09")
    // The plugin's engine-scoped coroutine scope (Dispatchers.Main).
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    // ActivityResultLauncher / ActivityResultRegistry types for the
    // Activity-owned permission-launcher bridge.
    implementation("androidx.activity:activity:1.9.3")
}
