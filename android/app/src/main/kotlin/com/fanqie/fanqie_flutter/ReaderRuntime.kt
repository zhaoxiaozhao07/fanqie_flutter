package com.fanqie.fanqie_flutter

import android.content.ContentValues
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object ReaderRuntime {
    private var cachedEngine: FlutterEngine? = null
    private var activity: WeakReference<MainActivity>? = null
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private val files = Executors.newSingleThreadExecutor()
    var volumeKeyScrollEnabled = false

    fun attach(value: MainActivity) { activity = WeakReference(value) }
    fun detach(value: MainActivity) {
        if (activity?.get() === value) activity = null
    }
    fun emit(method: String, args: Any? = null) {
        main.post { channel?.invokeMethod(method, args) }
    }
    fun engine(context: Context): FlutterEngine {
        cachedEngine?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        cachedEngine = engine
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.fanqie.fanqie_flutter/download")
        channel!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val window = activity?.get()?.window
                        if (call.argument<Boolean>("enabled") == true) window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(window != null)
                    }
                    "setVolumeKeyScrollEnabled" -> {
                        volumeKeyScrollEnabled = call.argument<Boolean>("enabled") == true
                        result.success(true)
                    }
                    "getBatteryLevel" -> result.success((app.getSystemService(Context.BATTERY_SERVICE) as BatteryManager)
                        .getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
                    "getNetworkType" -> {
                        val manager = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val caps = manager.getNetworkCapabilities(manager.activeNetwork)
                        result.success(when {
                            caps == null -> "offline"
                            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                            else -> "unknown"
                        })
                    }
                    "readTtsSecret" -> result.success(ReaderSecrets.read(app))
                    "getReaderCapabilities" -> {
                        val engines = app.packageManager.queryIntentServices(
                            android.content.Intent(android.speech.tts.TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
                        result.success(mapOf(
                            "mediaPlayback" to true,
                            "secureStorage" to true,
                            "ttsEngines" to engines.size,
                            "sdk" to Build.VERSION.SDK_INT,
                            "foreground" to (activity?.get()?.hasWindowFocus() == true),
                            "interactive" to (app.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager).isInteractive
                        ))
                    }
                    "writeTtsSecret" -> result.success(ReaderSecrets.write(app, call.argument<String>("value") ?: ""))
                    "saveToDownloads" -> {
                        val source = call.argument<String>("filePath") ?: ""
                        val name = File(call.argument<String>("fileName") ?: "export.txt").name
                        val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                        files.execute {
                            val saved = saveToDownloads(app, source, name, mime)
                            main.post { result.success(saved) }
                        }
                    }
                    "initNativeTts", "speakNativeTts", "playAudioFile", "pauseAudio", "resumeAudio",
                    "stopNativeTts", "stopAudio", "stopPlayback", "setAudioVolume", "setSleepDeadline",
                    "updateMediaPlaybackState", "releasePlaybackService", "getPlaybackState" -> {
                        @Suppress("UNCHECKED_CAST")
                        ReaderPlaybackService.dispatch(app, call.method, call.arguments as? Map<String, Any?> ?: emptyMap(), result)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("READER_PLATFORM", "系统操作未完成，请重试", null)
            }
        }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return engine
    }

    private fun saveToDownloads(context: Context, source: String, name: String, mime: String): Boolean {
        try {
            if (!File(source).isFile || name.isBlank()) return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val resolver = context.contentResolver
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/fanqie")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return false
                try {
                    val output = resolver.openOutputStream(uri) ?: throw IllegalStateException()
                    output.use { stream -> File(source).inputStream().use { it.copyTo(stream) } }
                    values.clear()
                    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                } catch (error: Exception) {
                    resolver.delete(uri, null, null)
                    throw error
                }
            } else {
                @Suppress("DEPRECATION")
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "fanqie")
                if (!dir.exists() && !dir.mkdirs()) return false
                File(source).inputStream().use { input -> File(dir, name).outputStream().use { input.copyTo(it) } }
            }
            return true
        } catch (_: Exception) { return false }
    }
}

/** Only ciphertext is stored in preferences. The AES key never leaves Keystore. */
private object ReaderSecrets {
    private const val ALIAS = "fanqie.reader.tts.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    fun write(context: Context, text: String): Boolean {
        val prefs = context.getSharedPreferences("reader_secure", Context.MODE_PRIVATE)
        if (text.isEmpty()) return prefs.edit().remove("tts").commit()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(text.toByteArray(Charsets.UTF_8))
        return prefs.edit().putString("tts", "${Base64.encodeToString(cipher.iv, Base64.NO_WRAP)}:${Base64.encodeToString(encrypted, Base64.NO_WRAP)}").commit()
    }
    fun read(context: Context): String? {
        val value = context.getSharedPreferences("reader_secure", Context.MODE_PRIVATE).getString("tts", null) ?: return null
        val parts = value.split(':')
        require(parts.size == 2)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
        return String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
    }
}
