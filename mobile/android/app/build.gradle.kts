plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}
android {
    namespace = "br.edu.ecopulse"
    compileSdk = 36
    ndkVersion = "27.0.12077973"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }
    defaultConfig {
        applicationId = "br.edu.ecopulse"
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    buildTypes { release { signingConfig = signingConfigs.getByName("debug") } }
}
flutter { source = "../.." }
