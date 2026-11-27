# flutter_local_notifications は予約通知を Gson で SharedPreferences に保存・復元する。
# R8 がジェネリクスの型情報やモデルクラスを削ると、リリースビルドで
# 「TypeToken must be created with a type argument」となり通知を予約できない。
# 以下はプラグインの example（17.2.4）にある Gson 用ルールに、プラグイン本体の保持を加えたもの。

## Gson rules
# Gson uses generic type information stored in a class file when working with fields. Proguard
# removes such information by default, so configure it to keep all of it.
-keepattributes Signature

# For using GSON @Expose annotation
-keepattributes *Annotation*

# Gson specific classes
-dontwarn sun.misc.**

# Prevent proguard from stripping interface information from TypeAdapter, TypeAdapterFactory,
# JsonSerializer, JsonDeserializer instances (so they can be used in @JsonAdapter)
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# Prevent R8 from leaving Data object members always null
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}

# Retain generic signatures of TypeToken and its subclasses with R8 version 3.0 and higher.
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken

## flutter_local_notifications
# 予約内容のモデルクラスはフィールド名のまま Gson でシリアライズされるため、難読化・削除させない
-keep class com.dexterous.** { *; }
