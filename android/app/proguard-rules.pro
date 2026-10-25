# libbox (gomobile) calls back into Java by name through JNI.
-keep class go.** { *; }
-keep class io.nekohasekai.** { *; }
-keepclassmembers class * implements io.nekohasekai.libbox.PlatformInterface { *; }
-keep class app.kumo.vpn.** { *; }
-dontwarn go.**
-dontwarn io.nekohasekai.**
