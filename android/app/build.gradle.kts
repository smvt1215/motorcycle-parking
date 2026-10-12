import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val mapsProperties = Properties()
val mapsPropertiesFile = rootProject.file("maps.properties")
if (mapsPropertiesFile.exists()) {
    mapsPropertiesFile.inputStream().use { mapsProperties.load(it) }
}

val cdEnvironment = System.getenv("CD_ENVIRONMENT")
val cdKeystore = System.getenv("ANDROID_KEYSTORE_PATH")

android {
    namespace = "tw.motopark.motorcycle_parking"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "tw.motopark.motorcycle_parking"
        manifestPlaceholders["appLabel"] = "機車停車指南"
        manifestPlaceholders["appIcon"] = "@mipmap/ic_launcher"
        manifestPlaceholders["oauthScheme"] = "tw.motopark.motorcycleparking"
        manifestPlaceholders["googleMapsApiKey"] = mapsProperties.getProperty("apiKey", "")
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (cdKeystore != null) {
            require(cdEnvironment in listOf("staging", "production"))
            create("cd") {
                storeFile = file(cdKeystore)
                storePassword = System.getenv("ANDROID_STORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    flavorDimensions += "environment"
    productFlavors {
        create("production") {
            dimension = "environment"
            if (cdEnvironment == "production" && cdKeystore != null) {
                signingConfig = signingConfigs.getByName("cd")
            }
        }
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
            manifestPlaceholders["appLabel"] = "機車停車指南 β"
            manifestPlaceholders["appIcon"] = "@drawable/ic_launcher_staging"
            manifestPlaceholders["oauthScheme"] = "tw.motopark.motorcycleparking.staging"
            if (cdEnvironment == "staging" && cdKeystore != null) {
                signingConfig = signingConfigs.getByName("cd")
            }
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
}
