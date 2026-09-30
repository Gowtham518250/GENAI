plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")  // Google Services plugin for Firebase
}

android {
    namespace = "com.retailmind.app"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion
    val signingProperties = java.util.Properties().apply {
        val propertiesFile = rootProject.file("key.properties")
        if (propertiesFile.exists()) {
            propertiesFile.inputStream().use { load(it) }
        }
    }

    fun signingValue(propertyName: String, environmentName: String): String? {
        return System.getenv(environmentName)?.takeIf { it.isNotBlank() }
            ?: signingProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() }
    }

    val releaseKeystorePath = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")
    val releaseStorePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
    val releaseKeyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
    val releaseKeyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
    val hasReleaseSigning =
        !releaseKeystorePath.isNullOrBlank() &&
        !releaseStorePassword.isNullOrBlank() &&
        !releaseKeyAlias.isNullOrBlank() &&
        !releaseKeyPassword.isNullOrBlank()

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.retailmind.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseStorePassword!!
                keyAlias = releaseKeyAlias!!
                keyPassword = releaseKeyPassword!!
            }
        }
    }

    buildTypes {
        release {
            // 🔧 CRITICAL: Set your own signing config before publishing to Play Store.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            // 🔧 FIX: this was missing entirely — the release build runs R8
            // minification (Flutter's default) with zero app-level keep
            // rules, which is what caused the WorkDatabase crash. See
            // proguard-rules.pro for the full explanation.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.sqlite:sqlite-framework:2.4.0")
    implementation("androidx.sqlite:sqlite:2.4.0")
}

// Never silently produce a debug-signed production artifact.
// Debug builds remain usable without signing secrets; release builds require
// an explicitly configured release keystore and credentials.
gradle.taskGraph.whenReady {
    val isReleaseBuild = allTasks.any { task ->
        task.name.contains("Release", ignoreCase = true)
    }
    if (isReleaseBuild && !hasReleaseSigning) {
        throw GradleException(
            "Release signing is not configured. Set ANDROID_KEYSTORE_PATH, " +
                "ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD " +
                "or provide android/key.properties."
        )
    }
}
