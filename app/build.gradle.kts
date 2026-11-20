
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val signingProps = Properties()
val signingPropsFile = rootProject.file("signing.properties")

if (signingPropsFile.exists()) {
    signingPropsFile.inputStream().use {
        signingProps.load(it)
    }
}

val hasReleaseSigning = listOf(
    "KEYSTORE_FILE",
    "KEYSTORE_PASSWORD",
    "KEY_ALIAS",
    "KEY_PASSWORD"
).all { key ->
    !signingProps.getProperty(key).isNullOrBlank()
} && run {
    // A signing.properties that points at a keystore which is not on disk (the
    // usual case on a fresh clone, because keystore/ is gitignored) must not be
    // treated as "release signing is configured": Gradle would fail on a
    // missing storeFile instead of falling back to the debug key.
    val store = signingProps.getProperty("KEYSTORE_FILE")
    store != null && rootProject.file(store).exists()
}

android {
    namespace = "df.root"
    compileSdk = 37

    buildFeatures {
        buildConfig = true
        compose = true
    }

    defaultConfig {
        applicationId = "df.root"
        minSdk = 31
        targetSdk = 37
        versionCode = 496
        versionName = "4.9.6"

        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        // A copy of the user's existing debug keystore, so the new APK keeps
        // the same signature and installs as an update. The default
        // ~/.android/debug.keystore cannot be used because the build sandbox
        // may not create its .lock file.
        create("debugLocal") {
            storeFile = rootProject.file("keystore/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        if (hasReleaseSigning) {
            create("release") {
                // signing.properties paths are relative to the repository root,
                // matching README.md (keystore/release.keystore).
                storeFile = rootProject.file(signingProps.getProperty("KEYSTORE_FILE"))
                storePassword = signingProps.getProperty("KEYSTORE_PASSWORD")
                keyAlias = signingProps.getProperty("KEY_ALIAS")
                keyPassword = signingProps.getProperty("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            isDebuggable = true
            isMinifyEnabled = false
            isShrinkResources = false

            // Same debug certificate as the previous DFRoot builds.
            signingConfig = signingConfigs.getByName("debugLocal")
        }

        release {
            // 有 signing.properties 就用你自己的 key，沒有就退回版控內的
            // debug keystore（與舊版 DFRoot 同憑證，可直接覆蓋安裝）。
            // 少了這個 else，assembleRelease 只會產出 app-release-unsigned.apk，
            // 那種檔案裝不起來，CI 也沒東西可以掛上 release。
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debugLocal")
            }

            isMinifyEnabled = true
            isShrinkResources = true

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }

        // Size-optimized sideload build: R8 + resource shrinking, signed with
        // the same debug certificate as the previous DFRoot APKs so it installs
        // as an update. `assembleSlim` is the small deliverable; `assembleDebug`
        // stays unminified for development.
        create("slim") {
            initWith(getByName("debug"))
            isDebuggable = false
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName("debugLocal")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            matchingFallbacks += listOf("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    lint {
        checkReleaseBuilds = false
    }

    externalNativeBuild {
        cmake {
            path("src/main/jni/CMakeLists.txt")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
        resources {
            // Dependency metadata that has no runtime use in this APK.
            excludes += listOf(
                "META-INF/*.version",
                "META-INF/androidx/**/LICENSE.txt",
                "DebugProbesKt.bin",
            )
        }
    }
}

androidComponents {
    onVariants { variant ->
        variant.outputs.forEach { output ->
            output.outputFileName.set(
                output.versionName.map { vn ->
                    "DFRoot_${vn}.apk"
                }
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

dependencies {
    // MIUIX 0.9.4 is a Compose Multiplatform UI library. Its Android variant
    // pulls Compose Foundation 1.12 and the matching Kotlin runtime in.
    // miuix-icons is intentionally NOT used: only ten glyphs are needed and
    // the artifact is ~13 MB of dex in a debug build. DfIcons.kt draws them.
    implementation(libs.miuix.ui)

    // ComponentActivity + setContent + edge-to-edge plumbing.
    implementation(libs.androidx.activity.compose)
}
