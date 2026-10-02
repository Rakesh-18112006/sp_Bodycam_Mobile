allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Forces every Android subproject (including plugin modules like
// package:jni's `:jni`, which declares its OWN `ndkVersion =
// flutter.ndkVersion` -- not just this app's own `:app` module) onto the
// NDK version already fully installed on disk -- see
// android/app/build.gradle.kts's ndkVersion doc comment for why: Flutter's
// bundled default NDK side-by-side download from Google's SDK repo
// repeatedly failed/timed out over this network, and a plugin module
// picking a *different* un-pinned NDK version than :app re-triggers that
// same failing download for itself alone.
//
// MUST be wrapped in afterEvaluate: a root-level `subprojects {}` block's
// own content runs BEFORE each subproject's own build.gradle body (a
// well-known Gradle evaluation-order gotcha) -- a plain, unwrapped
// `ndkVersion = ...` assignment here would fire too early and then
// immediately be overwritten right back by :jni's own later
// `ndkVersion flutter.ndkVersion` line in that same script. afterEvaluate
// defers until each subproject's entire script has already run, AND
// (since Gradle fires afterEvaluate callbacks in registration order, and
// this one is registered before that subproject's own script -- hence
// before AGP's own internal NDK-validation afterEvaluate -- even gets
// applied) still runs before AGP validates the NDK path.
//
// MUST be registered before `evaluationDependsOn(":app")` below: that call
// forces :app to fully evaluate immediately as a side effect, and
// Project.afterEvaluate() throws if called on a project that has already
// finished evaluating -- so this has to run first, while every subproject
// (including :app) is still pre-evaluation.
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android")
        if (android is com.android.build.gradle.BaseExtension) {
            android.ndkVersion = "27.1.12297006"
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
