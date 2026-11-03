plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
    // ktlint is also applied to the root project, where it only checks build.gradle.kts / settings.gradle.kts here;
    // the app module applies it in its own script
    alias(libs.plugins.ktlint)
    alias(libs.plugins.detekt) apply false
}

// All Gradle output goes to Build/Android/Gradle/ at the repository root (see AGENTS.md); the Makefile copies the APK
// and AAB to Build/Android/Debug/ and Release/
allprojects {
    layout.buildDirectory.set(rootDir.resolve("../Build/Android/Gradle/${project.name}"))
}

// Rules live in Android/.editorconfig (ktlint_code_style etc.). The engine version is pinned in libs.versions.toml so it
// does not drift with the plugin default. Auto-fix: make android-format (ktlintFormat).
ktlint {
    version.set(libs.versions.ktlint.engine)
}
