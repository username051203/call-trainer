package com.nic.calltrainer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Bundle
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

    private lateinit var statusText: TextView
    private lateinit var transcriptText: TextView
    private lateinit var callTimer: Chronometer
    private lateinit var callButton: Button

    private var inCall = false

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
        }
    }

    // Routes audio like an actual phone call: earpiece out, call mic in —
    // not the loud bottom speaker.
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
        routeAudioLikeCall()
        statusText.text = "Live"
        callTimer.visibility = TextView.VISIBLE
        callTimer.base = SystemClock.elapsedRealtime()
        callTimer.start()
        callButton.text = "End Call"
        transcriptText.text = ""

        // Opening line from the AI persona. Once scenarios are wired up
        // this should come from the scenario definition, not be hardcoded.
        speak("Hi, thanks for coming in today. Can you start by telling me a bit about yourself?") {
            listenForUser()
        }
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
        // TODO: replace with the real Groq call. This stub keeps the
        // audio loop (listen -> respond -> speak -> listen) testable
        // end to end before the AI brain is wired in.
        val reply = getStubResponse(userText)
        speak(reply) { listenForUser() }
    }

    private fun getStubResponse(userText: String): String {
        return "That's interesting — can you tell me more about that?"
    }

    private fun appendTranscript(line: String) {
        transcriptText.append("$line\n")
    }

    override fun onDestroy() {
        speechRecognizer.destroy()
        tts.shutdown()
        super.onDestroy()
    }
}
