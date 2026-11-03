# The UniFFI-generated Kotlin bindings call into the core via JNA reflection: keep JNA and the binding classes
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class com.gicek.kakey.core.** { *; }
-dontwarn java.awt.**
# camera-view references recording classes from the excluded camera-video module (the app only uses preview and frame analysis)
-dontwarn androidx.camera.video.**
