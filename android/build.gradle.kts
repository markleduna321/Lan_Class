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

// Force all Android library plugin modules to compile against SDK 36.
// file_picker (and others) ship with compileSdkVersion 34, which now fails
// the AAR metadata check from flutter_plugin_android_lifecycle (requires >=36).
// gradle.afterProject fires after each project's build script has run,
// so our value is applied last and wins over the plugin's own declaration.
gradle.afterProject {
    extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
        ?.let { lib -> if ((lib.compileSdk ?: 0) < 36) lib.compileSdk = 36 }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
