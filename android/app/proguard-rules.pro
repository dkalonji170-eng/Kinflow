# Garde-fous ProGuard (utilisés si la minification est réactivée).
# Les plugins suivants utilisent JNI / réflexion et doivent rester intacts.

# ObjectBox (stockage natif FMTC)
-keep class io.objectbox.** { *; }
-keep class **.MyObjectBox { *; }
-keep class io.objectbox.BuildConfig { *; }
-keepnames class io.objectbox.annotation.** { *; }

# Supabase / GoTrue / PostgREST / Realtime
-keep class supabase.** { *; }
-keep class io.supabase.** { *; }
-keep class com.supabase.** { *; }

# app_links (gestion des liens profonds)
-keep class com.llfbandit.app_links.** { *; }

# Geolocator / Compass (réflexion sur les services)
-keep class com.baseflow.geolocator.** { *; }
-keep class com.hemanthraj.fluttercompass.** { *; }

# Flutter embedding
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
