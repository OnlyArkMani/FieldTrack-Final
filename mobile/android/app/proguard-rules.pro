# FieldTrack — ProGuard/R8 rules for release builds.
#
# minifyEnabled + shrinkResources (enabled in build.gradle.kts) remove unused
# code and rename classes to save space. Plugins that use reflection or JNI
# need explicit "keep" rules or R8 strips classes they load by name at
# runtime, causing crashes that only show up in release builds (never in
# debug). Each section below is a plugin used by this app.

# ── Flutter engine ──────────────────────────────────────────────────────
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# ── Dio (HTTP client) ────────────────────────────────────────────────────
# Dio uses dart:ffi / okhttp under the hood on some platforms; keep okhttp
# and its annotation classes so request/response interceptors don't break.
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }

# ── Firebase Cloud Messaging ─────────────────────────────────────────────
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# ── sqflite (local SQLite database) ──────────────────────────────────────
-keep class com.tekartik.sqflite.** { *; }

# ── geolocator / background location ─────────────────────────────────────
-keep class com.baseflow.geolocator.** { *; }
-keep class com.lyokone.location.** { *; }

# ── General Dart/Kotlin reflection safety ────────────────────────────────
-keepattributes Signature, *Annotation*, EnclosingMethod, InnerClasses
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
