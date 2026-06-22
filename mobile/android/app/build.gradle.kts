plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.fieldtrack.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.fieldtrack.app"
        // minSdk: spec floor is 21 (background_locator_2 / firebase_messaging
        // require >=21). Take the greater of 21 and whatever Flutter/plugins
        // demand so we never drop below the floor.
        minSdk = maxOf(21, flutter.minSdkVersion)
        // targetSdk pinned to 34 (Android 14) per spec — the foreground
        // location service behaviour we depend on is governed by API 34 rules.
        targetSdk = 34
        // Driven by pubspec `version:` (currently 0.1.0+1 => versionName 0.1.0,
        // versionCode 1). Bump the pubspec build number before each store
        // upload; Play rejects a duplicate versionCode.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    // Release signing. Until a keystore is provisioned the release build is
    // signed with the DEBUG key so `flutter build apk --release` works for
    // internal testing. BEFORE PLAY STORE SUBMISSION: create a keystore and a
    // key.properties file (storeFile/storePassword/keyAlias/keyPassword), load
    // it here, and point release.signingConfig at it. A debug-signed APK is
    // rejected by the Play Console.
    val keystorePropsFile = rootProject.file("key.properties")
    val hasReleaseKeystore = keystorePropsFile.exists()
    val releaseProps = java.util.Properties().apply {
        if (hasReleaseKeystore) keystorePropsFile.inputStream().use { load(it) }
    }
    if (hasReleaseKeystore) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseProps.getProperty("storeFile"))
                storePassword = releaseProps.getProperty("storePassword")
                keyAlias = releaseProps.getProperty("keyAlias")
                keyPassword = releaseProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Real keystore when present (key.properties at the android/ root);
            // otherwise fall back to debug keys for internal testing.
            signingConfig = if (hasReleaseKeystore)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")

            // Shrink + obfuscate the release APK. Rules for Flutter/Dio/
            // Firebase/sqflite/geolocator/background_locator_2 live in
            // proguard-rules.pro — without them minification strips classes
            // those plugins load via reflection and the app crashes at runtime.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    implementation("androidx.multidex:multidex:2.0.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
