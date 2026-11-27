# 保留 Flutter 引擎、插件及原生通道入口类
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# 保留本应用原生桥接与前台服务类
-keep class com.fanqie.fanqie_flutter.** { *; }

# 忽略未启用 Play Store Deferred Components 时 Flutter 引擎内部对 Play Core 的可选引用
-dontwarn com.google.android.play.core.**
