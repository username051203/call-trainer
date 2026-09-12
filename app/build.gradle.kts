plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val groqApiKey: String = System.getenv("GROQ_API_KEY") ?: ""

android {
    namespace = "com.nic.calltrainer"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.nic.calltrainer"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
        buildConfigField("String", "GROQ_API_KEY", "\"$groqApiKey\"")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
