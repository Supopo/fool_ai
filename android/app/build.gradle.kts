plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun loadKeystoreProperties(file: File): Map<String, String> {
    if (!file.exists()) return emptyMap()
    val values = linkedMapOf<String, String>()
    file.readLines().forEach { raw ->
        val line = raw.trim()
        if (line.isEmpty() || line.startsWith("#")) return@forEach
        val index = line.indexOf('=')
        if (index <= 0) return@forEach
        values[line.substring(0, index).trim()] = line.substring(index + 1).trim()
    }
    return values
}

val keystoreProperties = loadKeystoreProperties(rootProject.file("keystore.properties"))

android {
    namespace = "com.example.fool_ai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.fool_ai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = 2
        versionName = "1.0.1"
        // Most phones are arm64. Skipping other ABIs makes debug install much faster.
        ndk {
            abiFilters.clear()
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        create("release") {
            val storeFileName = keystoreProperties["storeFile"]
            require(!storeFileName.isNullOrBlank()) {
                "Missing storeFile in android/keystore.properties"
            }
            storeFile = rootProject.file(storeFileName)
            storePassword = keystoreProperties["storePassword"]
            keyAlias = keystoreProperties["keyAlias"]
            keyPassword = keystoreProperties["keyPassword"]
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}
