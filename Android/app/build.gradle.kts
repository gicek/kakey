import com.android.build.api.artifact.SingleArtifact
import io.gitlab.arturbosch.detekt.Detekt
import javax.inject.Inject

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ktlint)
    alias(libs.plugins.detekt)
}

val repo: File = rootDir.parentFile

/** Output of `make core-android`: the Rust core shared libraries, the UniFFI Kotlin bindings, and the host core for JVM unit tests. */
val coreAndroid: File = repo.resolve("Build/Core/android")

/** Version numbers are defined only in Apple/project.yml (see AGENTS.md); Android reads the same file. */
fun appleSetting(name: String): String {
    val yml = repo.resolve("Apple/project.yml").readText()
    return requireNotNull(Regex("""$name:\s*"?([0-9.]+)""").find(yml)) { "Apple/project.yml is missing $name" }.groupValues[1]
}

/**
 * Cloud backup developer keys (`cloud-keys.toml`, see docs/DEVELOPMENT.md). Only the OAuth callback schemes are read and
 * injected into the manifest, using the same rules as kakey-ffi's build.rs (Dropbox `db-<app key>`, Microsoft
 * `msal<client id>`, both lowercase; Google the client ID in reverse DNS notation, `com.googleusercontent.apps.<id>`, from the
 * same iOS-type client the Apple apps use). Only `key = "value"` lines are recognized; the format is validated by
 * `make cloud-config` and the core build. Unconfigured schemes get placeholders that no browser will ever open.
 */
fun oauthSchemes(): Map<String, String> {
    val file = repo.resolve("cloud-keys.toml")
    val values = mutableMapOf<String, String>()
    if (file.isFile) {
        var section = ""
        file.readLines().forEach { raw ->
            val line = raw.substringBefore('#').trim()
            Regex("""^\[(\w+)]$""").find(line)?.let { section = it.groupValues[1] }
            Regex("""^(\w+)\s*=\s*"([A-Za-z0-9.-]*)"$""").find(line)?.let { values["$section.${it.groupValues[1]}"] = it.groupValues[2] }
        }
    }
    fun scheme(key: String, format: String, placeholder: String) =
        values[key]?.takeIf { it.isNotBlank() }?.let { format.format(it.lowercase()) } ?: placeholder
    return mapOf(
        "dropboxScheme" to scheme("dropbox.app_key", "db-%s", "com.gicek.kakey.unused-dropbox"),
        "dropboxFullScheme" to scheme("dropbox.full_app_key", "db-%s", "com.gicek.kakey.unused-dropbox-full"),
        "microsoftScheme" to scheme("microsoft.client_id", "msal%s", "com.gicek.kakey.unused-microsoft"),
        "googleScheme" to (
            values["google.client_id"]?.takeIf { it.isNotBlank() }?.split('.')?.reversed()?.joinToString(".")?.lowercase()
                ?: "com.gicek.kakey.unused-google"
            ),
    )
}

/**
 * Generates strings.xml for all three languages from the String Catalog and copies the verification code font
 * (scripts/android_strings.py).
 */
abstract class GenerateAndroidResources : DefaultTask() {
    @get:InputFile abstract val script: RegularFileProperty

    @get:InputFile abstract val catalog: RegularFileProperty

    @get:InputFile abstract val font: RegularFileProperty

    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @get:Inject abstract val exec: ExecOperations

    @TaskAction
    fun generate() {
        exec.exec { commandLine("python3", script.get().asFile.path, "--out", outputDir.get().asFile.path) }
    }
}

/**
 * The merged manifest may contain only one network permission, `INTERNET`, used solely for cloud storage backup
 * (see docs/SECURITY.md). Libraries merge in their own permissions and `tools:node="remove"` in the source manifest strips
 * them; this task checks every variant before packaging and unit tests and fails the build if one slipped through.
 */
abstract class CheckManifestPermissions : DefaultTask() {
    @get:InputFile abstract val manifest: RegularFileProperty

    @get:Input abstract val forbidden: ListProperty<String>

    @TaskAction
    fun check() {
        val declared = Regex("""<uses-permission[^>]*android:name="([^"]+)"""").findAll(manifest.get().asFile.readText()).map {
            it.groupValues[1]
        }.toList()
        val found = declared.filter { it in forbidden.get() }
        if (found.isNotEmpty()) {
            throw GradleException(
                "Merged manifest contains forbidden network permissions $found (${manifest.get().asFile}); " +
                    "remove them with tools:node=\"remove\" in AndroidManifest.xml or drop the dependency that adds them",
            )
        }
    }
}

// INTERNET is only for cloud storage backup; all other network permissions are forbidden (see docs/SECURITY.md)
val networkPermissions = listOf(
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.CHANGE_NETWORK_STATE",
    "android.permission.CHANGE_WIFI_STATE",
)

val generateResources = tasks.register<GenerateAndroidResources>("generateKakeyResources") {
    script.set(repo.resolve("scripts/android_strings.py"))
    catalog.set(repo.resolve("Apple/Shared/Resources/Localizable.xcstrings"))
    font.set(repo.resolve("Apple/Shared/Resources/Fonts/AtkinsonHyperlegibleMono-Variable.ttf"))
    outputDir.set(layout.buildDirectory.dir("generated/kakey-res"))
}

/**
 * Release signing: `make android-release` passes the keystore from local.mk as Gradle properties
 * (kakeyKeystore / kakeyKeystorePassword / kakeyKeyAlias / kakeyKeyPassword); key material is never committed.
 * Without them the release is signed with the debug keystore, so the build can only be installed locally for testing and
 * cannot be distributed, mirroring the Mac's ad-hoc signing when no certificate is configured.
 */
val releaseKeystore: File? = (findProperty("kakeyKeystore") as String?)?.takeIf { it.isNotBlank() }?.let { repo.resolve(it) }

android {
    namespace = "com.gicek.kakey.android"
    // AndroidX (adaptive, activity, etc.) requires compiling against API 37; targetSdk stays at the current stable 36
    compileSdk = 37

    defaultConfig {
        // Same identifier as the Apple apps (see AGENTS.md)
        applicationId = "com.gicek.kakey"
        minSdk = 33
        targetSdk = 36
        versionName = appleSetting("MARKETING_VERSION")
        versionCode = appleSetting("CURRENT_PROJECT_VERSION").toInt()
        ndk { abiFilters += "arm64-v8a" }
        manifestPlaceholders += oauthSchemes()
        // Instrumented tests (src/androidTest, make test-android-device) run in the app sandbox on a device or emulator
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        create("release") {
            if (releaseKeystore != null) {
                require(releaseKeystore.isFile) { "Keystore set by ANDROID_KEYSTORE does not exist: $releaseKeystore" }
                storeFile = releaseKeystore
                storePassword = property("kakeyKeystorePassword") as String
                keyAlias = property("kakeyKeyAlias") as String
                keyPassword = property("kakeyKeyPassword") as String
            } else {
                initWith(getByName("debug"))
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("release")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    androidResources {
        generateLocaleConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    packaging {
        // JNA's desktop native library is only for JVM unit tests and stays out of the APK
        jniLibs.excludes += listOf("**/libjnidispatch.jnilib")
    }

    testOptions {
        // Disable system animations during instrumented tests so waitUntil does not wait for transitions
        animationsDisabled = true
        unitTests.all {
            // JVM unit tests load the same core compiled for the host (macOS arm64)
            it.systemProperty("jna.library.path", coreAndroid.resolve("host").path)
            it.systemProperty("kakey.repo", repo.path)
        }
    }

    // Android Lint is part of the make test-android gate: warnings fail the build and there is no baseline.
    // Checks that do not apply are disabled in lint.xml with a reason. Reports go to Build/Android/Gradle/app/reports/.
    lint {
        abortOnError = true
        warningsAsErrors = true
        checkDependencies = false
        lintConfig = file("lint.xml")
    }
}

// Rules live in Android/.editorconfig; the engine version is set in the root build.gradle.kts
ktlint {
    version.set(libs.versions.ktlint.engine)
}

// Rules live in Android/detekt.yml (only deviations from the defaults, each with a reason); formatting is left to ktlint,
// so detekt-formatting is not installed
detekt {
    buildUponDefaultConfig = true
    config.setFrom(rootProject.file("detekt.yml"))
    // By default only src/main and src/test are scanned; the debug / release variant sources need checking too
    source.setFrom("src")
}

tasks.withType<Detekt>().configureEach {
    jvmTarget = "21"
    reports {
        html.required.set(true)
        txt.required.set(true)
        xml.required.set(false)
        sarif.required.set(false)
        md.required.set(false)
    }
}

androidComponents {
    onVariants { variant ->
        variant.sources.res?.addGeneratedSourceDirectory(generateResources, GenerateAndroidResources::outputDir)
        variant.sources.jniLibs?.addStaticSourceDirectory(coreAndroid.resolve("jniLibs").path)
        variant.sources.kotlin?.addStaticSourceDirectory(coreAndroid.resolve("kotlin").path)

        val name = variant.name.replaceFirstChar { it.uppercase() }
        val checkPermissions = tasks.register<CheckManifestPermissions>("check${name}ManifestPermissions") {
            manifest.set(variant.artifacts.get(SingleArtifact.MERGED_MANIFEST))
            forbidden.set(networkPermissions)
        }
        // APKs, AABs and unit tests all run the manifest check first
        tasks.matching { it.name == "assemble$name" || it.name == "bundle$name" || it.name == "test${name}UnitTest" }
            .configureEach { dependsOn(checkPermissions) }
    }
}

// Warn before packaging a release signed with the debug keystore: it can only be installed locally (see docs/DEVELOPMENT.md)
tasks.matching { it.name == "assembleRelease" || it.name == "bundleRelease" }.configureEach {
    if (releaseKeystore == null) {
        doFirst {
            logger.warn(
                "Warning: ANDROID_KEYSTORE is not set (local.mk); the release is signed with the debug keystore and " +
                    "can only be installed locally, not distributed or published.",
            )
        }
    }
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.material3.adaptive)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.navigation3.runtime)
    implementation(libs.navigation3.ui)
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.fragment)
    implementation(libs.camera.camera2)
    implementation(libs.camera.lifecycle)
    // Only PreviewView + ImageAnalysis are used; exclude the recording module (it pulls in network permissions via media3)
    implementation(libs.camera.view) { exclude(group = "androidx.camera", module = "camera-video") }
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.documentfile)
    implementation(libs.zxing.core)
    implementation(libs.kotlinx.coroutines.android)
    // Cloud storage backup: executes the HTTP requests built by the core (data/cloud/OkHttpExecutor.kt)
    implementation(libs.okhttp)
    // The UniFFI Kotlin bindings call the core via JNA; the app uses the aar (with Android native libraries), JVM unit
    // tests use the desktop jar
    implementation("${libs.jna.get()}@aar")

    testImplementation(libs.junit)
    testImplementation(libs.jna)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.org.json)
    testImplementation(libs.okhttp.mockwebserver)

    // Instrumented tests (src/androidTest): drive the real UI through the Compose semantics tree in the app sandbox on a device
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.espresso.core)
}
