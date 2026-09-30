plugins {
    id("com.google.gms.google-services") version "4.4.0" apply false
}

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
    val moduleName = name
    val legacyNamespace = when (moduleName) {
        "blue_thermal_printer" -> "id.kakzaki.blue_thermal_printer"
        "record" -> "com.llfbandit.record"
        "telephony" -> "com.shounakmulay.telephony"
        else -> null
    }
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension> {
            if (legacyNamespace != null) {
                namespace = legacyNamespace
            }
            if (moduleName == "telephony") {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_1_8
                    targetCompatibility = JavaVersion.VERSION_1_8
                }
            }
        }
        extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension> {
            finalizeDsl { libraryExtension ->
                libraryExtension.compileSdk = 37
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
