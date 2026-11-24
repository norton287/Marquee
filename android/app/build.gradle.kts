import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.marquee.marquee"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The app's identity on devices and Google Play (permanent once uploaded).
        // The Kotlin namespace and channel names keep app.marquee.marquee.
        applicationId = "app.spindlecrank.marquee"
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

    // Google Play's upload key: android/key.properties (git-ignored) names a
    // keystore outside the repo. Only a Play build uses it (MARQUEE_PLAY=1,
    // see build-release.sh --play); sideloaded APKs stay on the debug key so
    // each one still installs over the last.
    val uploadKey = rootProject.file("key.properties")
    val forPlay = System.getenv("MARQUEE_PLAY") == "1"
    signingConfigs {
        if (forPlay && uploadKey.exists()) {
            create("upload") {
                val p = Properties().apply { uploadKey.inputStream().use { load(it) } }
                storeFile = file(p.getProperty("storeFile"))
                storePassword = p.getProperty("storePassword")
                keyAlias = p.getProperty("keyAlias")
                keyPassword = p.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (forPlay && !uploadKey.exists()) {
                throw GradleException("MARQUEE_PLAY=1 needs android/key.properties (the Play upload key)")
            }
            signingConfig = signingConfigs.getByName(if (forPlay) "upload" else "debug")
            // Names CarWatch.kt finds by reflection (see the file).
            proguardFiles("proguard-rules.pro")
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
