#!/usr/bin/env bash
# Run from inside ~/call-trainer
set -e

PKG_PATH="app/src/main/java/com/nic/calltrainer"

# --- AndroidManifest: add WAKE_LOCK permission for proximity screen-off ---
if ! grep -q "WAKE_LOCK" app/src/main/AndroidManifest.xml; then
    sed -i 's#<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />#<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />\n    <uses-permission android:name="android.permission.WAKE_LOCK" />#' app/src/main/AndroidManifest.xml
fi

# --- app/build.gradle.kts: add BuildConfig field for the Groq key ---
cat > app/build.gradle.kts << 'EOF'
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
EOF

# --- GroqClient.kt: talks to Groq's OpenAI-compatible chat endpoint ---
cat > "$PKG_PATH/GroqClient.kt" << 'EOF'
package com.nic.calltrainer

import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

object GroqClient {

    private const val ENDPOINT = "https://api.groq.com/openai/v1/chat/completions"
    private const val MODEL = "llama-3.3-70b-versatile"

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    interface ReplyCallback {
        fun onReply(text: String)
        fun onError(message: String)
    }

    // history is a list of ("user"|"assistant", text) pairs, oldest first.
    fun sendMessage(
        systemPrompt: String,
        history: List<Pair<String, String>>,
        callback: ReplyCallback
    ) {
        val messages = JSONArray()
        messages.put(JSONObject().put("role", "system").put("content", systemPrompt))
        for ((role, content) in history) {
            messages.put(JSONObject().put("role", role).put("content", content))
        }

        val body = JSONObject()
            .put("model", MODEL)
            .put("messages", messages)
            .put("temperature", 0.7)
            .put("max_tokens", 200)

        val requestBody = body.toString().toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url(ENDPOINT)
            .addHeader("Authorization", "Bearer ${BuildConfig.GROQ_API_KEY}")
            .post(requestBody)
            .build()

        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                callback.onError(e.message ?: "network error")
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    if (!it.isSuccessful) {
                        callback.onError("HTTP ${it.code}: ${it.body?.string()}")
                        return
                    }
                    val json = JSONObject(it.body?.string().orEmpty())
                    val reply = json.getJSONArray("choices")
                        .getJSONObject(0)
                        .getJSONObject("message")
                        .getString("content")
                    callback.onReply(reply.trim())
                }
            }
        })
    }
}
EOF

# --- MainActivity.kt: fix audio routing, add proximity screen-off, wire Groq ---
cat > "$PKG_PATH/MainActivity.kt" << 'EOF'
package com.nic.calltrainer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.widget.Button
import android.widget.Chronometer
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.Locale

class MainActivity : AppCompatActivity(), TextToSpeech.OnInitListener {

    private lateinit var audioManager: AudioManager
    private lateinit var speechRecognizer: SpeechRecognizer
    private lateinit var tts: TextToSpeech
    private var proximityWakeLock: PowerManager.WakeLock? = null

    private lateinit var statusText: TextView
    private lateinit var transcriptText: TextView
    private lateinit var callTimer: Chronometer
    private lateinit var callButton: Button

    private var inCall = false
    private val conversationHistory = mutableListOf<Pair<String, String>>()

    private val systemPrompt = """
        You are conducting a friendly but professional HR interview for a
        customer support role. Ask one question at a time, listen to the
        answer, and respond naturally the way a real interviewer would —
        brief acknowledgement, then either a relevant follow-up or the next
        question. Keep every reply short (2-3 sentences), spoken-style, no
        markdown, no lists.
    """.trimIndent()

    private val recordAudioRequestCode = 101

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.statusText)
        transcriptText = findViewById(R.id.transcriptText)
        callTimer = findViewById(R.id.callTimer)
        callButton = findViewById(R.id.callButton)

        audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        tts = TextToSpeech(this, this)
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)
        setupProximityWakeLock()

        ensureMicPermission()

        callButton.setOnClickListener {
            if (!inCall) startCall() else endCall()
        }
    }

    private fun ensureMicPermission() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.RECORD_AUDIO), recordAudioRequestCode
            )
        }
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            tts.language = Locale.US
            // Tell the audio framework this is call-style speech, not
            // music — this is what makes earpiece routing actually apply.
            tts.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
        }
    }

    // PROXIMITY_SCREEN_OFF_WAKE_LOCK isn't in the public SDK but every
    // dialer/calling app relies on it via reflection — there's no other
    // way to turn the screen off on proximity.
    private fun setupProximityWakeLock() {
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        val levelAndFlags = try {
            val field = PowerManager::class.java.getDeclaredField("PROXIMITY_SCREEN_OFF_WAKE_LOCK")
            field.getInt(null)
        } catch (e: Exception) {
            null
        }
        if (levelAndFlags != null && powerManager.isWakeLockLevelSupported(levelAndFlags)) {
            proximityWakeLock = powerManager.newWakeLock(levelAndFlags, "CallTrainer:Proximity")
        }
    }

    private fun routeAudioLikeCall() {
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        audioManager.isSpeakerphoneOn = false
    }

    private fun restoreAudioRouting() {
        audioManager.mode = AudioManager.MODE_NORMAL
        audioManager.isSpeakerphoneOn = false
    }

    private fun startCall() {
        inCall = true
        conversationHistory.clear()
        routeAudioLikeCall()
        proximityWakeLock?.let { if (!it.isHeld) it.acquire() }
        statusText.text = "Live"
        callTimer.visibility = TextView.VISIBLE
        callTimer.base = SystemClock.elapsedRealtime()
        callTimer.start()
        callButton.text = "End Call"
        transcriptText.text = ""

        val opener = "Hi, thanks for coming in today. Can you start by telling me a bit about yourself?"
        conversationHistory.add("assistant" to opener)
        speak(opener) { listenForUser() }
    }

    private fun endCall() {
        inCall = false
        speechRecognizer.stopListening()
        tts.stop()
        callTimer.stop()
        callTimer.visibility = TextView.INVISIBLE
        statusText.text = "Ready"
        callButton.text = "Start Call"
        restoreAudioRouting()
        proximityWakeLock?.let { if (it.isHeld) it.release() }
    }

    private fun speak(text: String, onDone: () -> Unit) {
        appendTranscript("AI: $text")
        statusText.text = "Speaking..."
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) {
                runOnUiThread {
                    if (inCall) {
                        statusText.text = "Live"
                        onDone()
                    }
                }
            }
            override fun onError(utteranceId: String?) {}
        })
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "utterance_${System.currentTimeMillis()}")
    }

    private fun listenForUser() {
        if (!inCall) return
        statusText.text = "Listening..."
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.US)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
        }
        speechRecognizer.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val userText = matches?.firstOrNull().orEmpty()
                if (userText.isNotBlank()) {
                    appendTranscript("You: $userText")
                    handleUserSpeech(userText)
                } else if (inCall) {
                    listenForUser()
                }
            }
            override fun onError(error: Int) {
                if (inCall) listenForUser()
            }
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        speechRecognizer.startListening(intent)
    }

    private fun handleUserSpeech(userText: String) {
        conversationHistory.add("user" to userText)
        statusText.text = "Thinking..."
        GroqClient.sendMessage(systemPrompt, conversationHistory, object : GroqClient.ReplyCallback {
            override fun onReply(text: String) {
                conversationHistory.add("assistant" to text)
                runOnUiThread {
                    if (inCall) speak(text) { listenForUser() }
                }
            }
            override fun onError(message: String) {
                runOnUiThread {
                    appendTranscript("[error: $message]")
                    if (inCall) speak("Sorry, could you repeat that?") { listenForUser() }
                }
            }
        })
    }

    private fun appendTranscript(line: String) {
        transcriptText.append("$line\n")
    }

    override fun onDestroy() {
        speechRecognizer.destroy()
        tts.shutdown()
        proximityWakeLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}
EOF

# --- CI workflow: pass the Groq secret in as an env var at build time ---
cat > .github/workflows/build.yml << 'EOF'
name: Build APK

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - name: Set up Android SDK
        uses: android-actions/setup-android@v3

      - name: Setup Gradle
        uses: gradle/actions/setup-gradle@v4
        with:
          gradle-version: '8.7'

      - name: Build debug APK
        env:
          GROQ_API_KEY: ${{ secrets.GROQ_API_KEY }}
        run: gradle assembleDebug

      - name: Upload APK
        uses: actions/upload-artifact@v4
        with:
          name: call-trainer-debug
          path: app/build/outputs/apk/debug/app-debug.apk
EOF

echo "Updated: audio routing, proximity screen-off, Groq integration."
