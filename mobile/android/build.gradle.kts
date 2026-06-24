allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Old plugins (e.g. background_locator_2) predate AGP's mandatory `namespace`
// and only declare `package=` in their AndroidManifest.xml. AGP 8+ needs
// `namespace` set in build.gradle, so backfill it here from the manifest
// rather than patching files in the pub cache (which `flutter pub get` wipes).
subprojects {
    afterEvaluate {
        val androidExt = project.extensions.findByName("android") ?: return@afterEvaluate
        // Force compileSdk >= 34 so old plugins can compile Java 17 source
        try {
            val setCompileSdk = androidExt.javaClass.methods.find {
                it.name == "setCompileSdkVersion" && it.parameterCount == 1 && it.parameterTypes[0] == Int::class.java
            }
            val getCompileSdk = androidExt.javaClass.methods.find {
                it.name == "getCompileSdkVersion" && it.parameterCount == 0
            }
            val current = getCompileSdk?.invoke(androidExt) as? Int ?: 0
            if (current < 36) setCompileSdk?.invoke(androidExt, 36)
        } catch (_: Exception) {}
        // Align Java + Kotlin JVM targets to 17
        try {
            val compileOptions = androidExt.javaClass.getMethod("getCompileOptions").invoke(androidExt)
            compileOptions.javaClass.getMethod("setSourceCompatibility", JavaVersion::class.java)
                .invoke(compileOptions, JavaVersion.VERSION_17)
            compileOptions.javaClass.getMethod("setTargetCompatibility", JavaVersion::class.java)
                .invoke(compileOptions, JavaVersion.VERSION_17)
        } catch (_: Exception) {}
        project.tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
                freeCompilerArgs.add("-Xsuppress-version-warnings")
            }
        }

        // background_locator_2 2.0.6 has a return-type mismatch that became a HARD compile
        // error in Kotlin 2.x: getLocationMapFromLocation() declares `HashMap<Any, Any>` but
        // `hashMapOf(...)` with mixed value types now infers a narrower type that Kotlin 2.x
        // refuses to coerce. There is no compiler flag that disables this check (it's plain
        // type inference, not an override check), so we patch the plugin source on disk.
        // The fix adds explicit `<Any, Any>` type args to the two hashMapOf() calls. This is
        // idempotent and re-applies on every build, so it survives `flutter pub get` wiping
        // the pub cache. Remove once we upgrade to a plugin version built for Kotlin 2.x.
        if (project.name == "background_locator_2") {
            val parserFile = project.file(
                "src/main/kotlin/yukams/app/background_locator_2/provider/LocationParserUtil.kt"
            )
            if (parserFile.exists()) {
                var text = parserFile.readText()
                val before = text
                // 1) Pin the map's type args to the declared return type. hashMapOf(...) alone
                //    infers a narrower, invariant HashMap that Kotlin 2.x won't coerce.
                text = text.replace("return hashMapOf(", "return hashMapOf<Any, Any>(")
                // 2) location.provider is String? — with non-null `<Any, Any>` values it must be
                //    coalesced, otherwise the nullable can't be passed as Pair<Any, Any>.
                text = text.replace("Keys.ARG_PROVIDER to location.provider", "Keys.ARG_PROVIDER to (location.provider ?: \"\")")
                if (text != before) {
                    parserFile.writeText(text)
                    println("[FieldTrack] Patched background_locator_2 LocationParserUtil.kt for Kotlin 2.x")
                }
            }

            // RUNTIME CRASH on Android 13+ (seen on Pixel / API 34+): the foreground
            // service dies at start with:
            //   IllegalArgumentException
            //   -> PreferencesHelper.createNotificationChannel
            //   -> Preconditions.checkArgument   (the message-less overload)
            // In AOSP that one message-less checkArgument is *only* the
            //   `!TextUtils.isEmpty(channel.getName())` guard — i.e. the notification
            // channel name reaching the OS is empty. (Importance is a valid LOW, so
            // it's ruled out.) The plugin builds the channel from `notificationChannelName`,
            // which can be blank on the onCreate / sticky-restart path before the intent
            // extras are applied. Coalesce it to a non-empty value at the construction
            // site so the channel name is never empty regardless of code path.
            // Idempotent + re-applies after `flutter pub get`.
            val serviceFile = project.file(
                "src/main/kotlin/yukams/app/background_locator_2/IsolateHolderService.kt"
            )
            if (serviceFile.exists()) {
                val svc = serviceFile.readText()
                val needle = "Keys.CHANNEL_ID, notificationChannelName,"
                if (svc.contains(needle)) {
                    serviceFile.writeText(
                        svc.replace(
                            needle,
                            "Keys.CHANNEL_ID, notificationChannelName.ifBlank { \"Location tracking\" },"
                        )
                    )
                    println("[FieldTrack] Patched background_locator_2 IsolateHolderService.kt (guaranteed non-empty notification channel name)")
                }
            }
        }
    }
}

subprojects {
    afterEvaluate {
        val androidExt = project.extensions.findByName("android") ?: return@afterEvaluate
        val getNamespace = androidExt.javaClass.methods.find { it.name == "getNamespace" && it.parameterCount == 0 }
        val currentNamespace = getNamespace?.invoke(androidExt) as? String
        if (currentNamespace.isNullOrEmpty()) {
            val manifestFile = project.file("src/main/AndroidManifest.xml")
            if (manifestFile.exists()) {
                val pkg = Regex("package=\"([^\"]+)\"").find(manifestFile.readText())?.groupValues?.get(1)
                if (!pkg.isNullOrEmpty()) {
                    val setNamespace = androidExt.javaClass.methods.find { it.name == "setNamespace" && it.parameterCount == 1 }
                    setNamespace?.invoke(androidExt, pkg)
                }
            }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
