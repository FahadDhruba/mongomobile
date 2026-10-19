# package:jni looks Java classes up by name at runtime; keep R8 from
# renaming or removing them in release builds.
-keep class com.github.dart_lang.jni.** { *; }
-keep class io.flutter.plugins.** { *; }
