plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.policebodycam.police_body_cam"
    // flutter_secure_storage requires compileSdk 37+.
    compileSdk = maxOf(flutter.compileSdkVersion, 35)
    // Pinned to the NDK version already present on this machine (see
    // /opt/homebrew/share/android-commandlinetools/ndk) instead of
    // flutter.ndkVersion's bundled default (28.2.13676358), whose
    // side-by-side download from Google's SDK repo repeatedly timed out
    // over this network.
    ndkVersion = "27.1.12297006"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.policebodycam.police_body_cam"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_webrtc (a livekit_client dependency) requires 24+.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Plain JVM unit tests only (android/app/src/test/kotlin) -- e.g.
    // VolumeGestureDetectorTest, which exercises the framework-independent
    // double-press/long-press/key-repeat state machine deterministically
    // via a fake clock/scheduler, without Robolectric, an emulator, or a
    // real device. Run with `./gradlew testDebugUnitTest`.
    testImplementation("junit:junit:4.13.2")

    // Direct CameraX dependencies for NativeRecordingManager.kt (background/
    // locked-screen recording -- see that file's doc comment for why camera
    // ownership had to move out of the Flutter `camera` plugin, which binds
    // to the Activity's own Lifecycle and is force-unbound by CameraX the
    // instant the Activity stops). Already present transitively via
    // camera_android_camerax's own build.gradle, which is where this exact
    // version comes from -- pinned to match it exactly rather than left to
    // float, so there is only ever one resolved androidx.camera version in
    // the APK.
    val camerax_version = "1.5.3"
    implementation("androidx.camera:camera-core:$camerax_version")
    implementation("androidx.camera:camera-camera2:$camerax_version")
    implementation("androidx.camera:camera-lifecycle:$camerax_version")
    implementation("androidx.camera:camera-video:$camerax_version")
    // ProcessCameraProvider.getInstance() returns a real Guava
    // ListenableFuture, but AndroidX libraries transitively pull in only
    // com.google.guava:listenablefuture:1.0 -- an empty stub/marker jar
    // with the same class name and no real implementation, used to avoid
    // forcing full Guava on consumers that never touch the future
    // directly. This app's NativeRecordingManager DOES call
    // ListenableFuture.addListener()/.get() directly (the officially
    // documented CameraX pattern), so without this the Kotlin compiler
    // resolves 'ListenableFuture' to the stub and fails with "Cannot
    // access class 'ListenableFuture'". Declaring the real artifact
    // explicitly makes Gradle's module-replacement rule (Guava's own
    // published metadata marks the two as mutually-exclusive capability
    // alternatives) resolve to the real one everywhere in the graph.
    implementation("com.google.guava:guava:33.3.1-android")
}
