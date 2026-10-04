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
subprojects {
    project.evaluationDependsOn(":app")
}

// Plugins declare their own compileSdk, and a stale one is a hard build failure
// rather than a warning: `file_picker` still compiles against android-34 while
// `flutter_plugin_android_lifecycle` (which it depends on) refuses to be consumed
// by anything below 36 —
//
//     Dependency ':flutter_plugin_android_lifecycle' requires libraries and
//     applications that depend on it to compile against version 36 or later
//     of the Android APIs. :file_picker is currently compiled against android-34.
//
// The app module's own `compileSdk` cannot fix that, because the failing module is
// the plugin's. Raising it here for every Android subproject keeps the app on
// Flutter's defaults and only corrects the plugins, and it is the documented
// escape hatch for exactly this mismatch.
subprojects {
    fun raisePluginCompileSdk() {
        val androidExtension = extensions.findByName("android")
        if (androidExtension is com.android.build.gradle.BaseExtension) {
            val current = androidExtension.compileSdkVersion?.removePrefix("android-")?.toIntOrNull()
            if (current == null || current < 36) {
                androidExtension.compileSdkVersion(36)
            }
        }
    }
    // `evaluationDependsOn(":app")` above can leave a project already evaluated
    // by the time this block runs, and `afterEvaluate` then throws.
    if (state.executed) raisePluginCompileSdk() else afterEvaluate { raisePluginCompileSdk() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
