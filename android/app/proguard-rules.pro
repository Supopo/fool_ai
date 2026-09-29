# Flutter embedding and plugins rely on reflection / JNI names.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugins.webviewflutter.** { *; }
-dontwarn io.flutter.embedding.**

# Flutter references Play Core classes that are not packaged in this app.
-dontwarn com.google.android.play.core.**
