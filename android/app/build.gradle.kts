plugins {
    id("com.android.application")
    id("kotlin-android")
    // Flutter plugin must be applied last
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.trudido.app"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.trudido.app"
        minSdk = 24  // Required for video_player and other media features
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "store"
    productFlavors {
        create("playstore") {
            dimension = "store"
            // PlayStore build - donations hidden via Dart define
        }
        create("fdroid") {
            dimension = "store"
            // FDroid build - donations enabled via --dart-define=IS_FDROID=true
        }
    }

    signingConfigs {
        create("release") {
            // Two ways in, so this works for a fork on any OS.
            //
            // Local builds: android/key.properties (gitignored), the standard
            // Flutter arrangement. CI: the four secrets, with the keystore
            // restored to the path in TRUDIDO_KEYSTORE.
            //
            // There is deliberately no hardcoded default path. This previously
            // pointed at the upstream author's D:/keystores directory, which
            // exists on exactly one machine, so every other build silently
            // produced an unsigned artifact.
            val keyProperties = java.util.Properties()
            val keyPropertiesFile = rootProject.file("key.properties")
            if (keyPropertiesFile.exists()) {
                keyPropertiesFile.inputStream().use { keyProperties.load(it) }
            }

            fun setting(propertyName: String, environmentName: String): String? =
                keyProperties.getProperty(propertyName)
                    ?: System.getenv(environmentName)?.takeIf { it.isNotEmpty() }

            val keystorePath = setting("storeFile", "TRUDIDO_KEYSTORE")
            val keystorePassword = setting("storePassword", "KEYSTORE_PASSWORD")
            val keystoreAlias = setting("keyAlias", "KEY_ALIAS")
            val keystoreKeyPassword = setting("keyPassword", "KEY_PASSWORD")

            // An unset GitHub secret arrives as an empty string rather than as
            // absent, which is why every value above is emptiness-checked. Without
            // that, signing is configured against a keystore decoded from nothing
            // and the build dies with an opaque JKS parse error.
            val resolvedKeystore = keystorePath?.let { rootProject.file(it) }
            if (resolvedKeystore != null &&
                resolvedKeystore.exists() &&
                !keystorePassword.isNullOrEmpty()
            ) {
                storeFile = resolvedKeystore
                storePassword = keystorePassword
                keyAlias = keystoreAlias
                keyPassword = keystoreKeyPassword
            } else {
                logger.warn(
                    "No signing key configured; the release build will be unsigned " +
                        "and Android will refuse to install it. See docs/building.md."
                )
            }
        }
    }

    buildTypes {
        getByName("release") {
            // Only use signing config if keystore exists and is configured
            val releaseSigningConfig = signingConfigs.getByName("release")
            if (releaseSigningConfig.storeFile?.exists() == true) {
                signingConfig = releaseSigningConfig
            }
            // Enable code shrinking, obfuscation, and optimization (standard for production)
            isMinifyEnabled = true
            // Remove unused resources to reduce APK size
            isShrinkResources = true
            // Apply ProGuard rules for proper minification
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    implementation("androidx.work:work-runtime-ktx:2.9.0")
    implementation("com.google.guava:guava:31.1-android")
}
