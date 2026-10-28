package com.fanqie.fanqie_flutter

import android.media.MediaPlayer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.KeyEvent
import android.content.Context
import android.content.ContentValues
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.view.WindowManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.Locale

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.fanqie.fanqie_flutter/download"
    private var volumeKeyScrollEnabled = false
    private var channelInstance: MethodChannel? = null
    private var nativeTts: TextToSpeech? = null
    private var nativeTtsReady = false
    private var mediaPlayer: MediaPlayer? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channelInstance = channel
        channel.setMethodCallHandler { call, result ->
            if (call.method == "saveToDownloads") {
                val filePath = call.argument<String>("filePath")
                val fileName = call.argument<String>("fileName")
                val mimeType = call.argument<String>("mimeType")
                
                if (filePath != null && fileName != null && mimeType != null) {
                    val success = saveFileToDownloads(filePath, fileName, mimeType)
                    if (success) {
                        result.success(true)
                    } else {
                        result.error("SAVE_FAILED", "Failed to save file via native code", null)
                    }
                } else {
                    result.error("INVALID_ARGS", "Missing arguments (filePath, fileName, mimeType)", null)
                }
            } else if (call.method == "setKeepScreenOn") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                if (enabled) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(true)
            } else if (call.method == "setVolumeKeyScrollEnabled") {
                volumeKeyScrollEnabled = call.argument<Boolean>("enabled") ?: false
                result.success(true)
            } else if (call.method == "getBatteryLevel") {
                try {
                    val bm = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                    val level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
                    result.success(level)
                } catch (e: Exception) {
                    result.success(-1)
                }
            } else if (call.method == "initNativeTts") {
                initNativeTtsInternal()
                result.success(true)
            } else if (call.method == "speakNativeTts") {
                val text = call.argument<String>("text") ?: ""
                val rate = call.argument<Double>("rate") ?: 1.0
                val id = call.argument<String>("id") ?: "tts_${System.currentTimeMillis()}"
                
                initNativeTtsInternal()

                // 如果尚未 ready，在异步线程中短暂等待就绪
                Thread {
                    var waitCount = 0
                    while (!nativeTtsReady && waitCount < 20) {
                        try { Thread.sleep(80) } catch (e: Exception) {}
                        waitCount++
                    }
                    runOnUiThread {
                if (nativeTtsReady && nativeTts != null) {
                    nativeTts?.setSpeechRate(rate.toFloat())
                            val speakRes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                                val params = android.os.Bundle().apply {
                                    putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, id)
                                }
                                nativeTts?.speak(text, TextToSpeech.QUEUE_FLUSH, params, id)
                            } else {
                                val params = HashMap<String, String>().apply {
                                    put(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, id)
                                }
                                @Suppress("DEPRECATION")
                                nativeTts?.speak(text, TextToSpeech.QUEUE_FLUSH, params)
                            }
                            if (speakRes == TextToSpeech.SUCCESS) {
                                result.success(true)
                            } else {
                                channelInstance?.invokeMethod("onTtsError", id)
                                result.success(false)
                            }
                } else {
                            channelInstance?.invokeMethod("onTtsError", id)
                    result.success(false)
                }
                    }
                }.start()
            } else if (call.method == "stopNativeTts") {
                nativeTts?.stop()
                result.success(true)
            } else if (call.method == "playAudioFile") {
                val filePath = call.argument<String>("filePath")
                if (filePath != null && File(filePath).exists()) {
                    try {
                        mediaPlayer?.release()
                        mediaPlayer = MediaPlayer().apply {
                            setDataSource(filePath)
                            setOnCompletionListener {
                                runOnUiThread {
                                    channelInstance?.invokeMethod("onAudioComplete", null)
                                }
                            }
                            setOnErrorListener { _, _, _ ->
                                runOnUiThread {
                                    channelInstance?.invokeMethod("onAudioError", null)
                                }
                                true
                            }
                            prepare()
                            start()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        e.printStackTrace()
                        result.success(false)
                    }
                } else {
                    result.success(false)
                }
            } else if (call.method == "pauseAudio") {
                try {
                    if (mediaPlayer?.isPlaying == true) {
                        mediaPlayer?.pause()
                    }
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            } else if (call.method == "resumeAudio") {
                try {
                    mediaPlayer?.start()
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            } else if (call.method == "stopAudio") {
                try {
                    mediaPlayer?.stop()
                    mediaPlayer?.release()
                    mediaPlayer = null
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun initNativeTtsInternal() {
        if (nativeTts == null) {
            nativeTts = TextToSpeech(this) { status ->
                if (status == TextToSpeech.SUCCESS) {
                    var langRes = nativeTts?.setLanguage(Locale.CHINA)
                    if (langRes == TextToSpeech.LANG_MISSING_DATA || langRes == TextToSpeech.LANG_NOT_SUPPORTED) {
                        langRes = nativeTts?.setLanguage(Locale.CHINESE)
                    }
                    if (langRes == TextToSpeech.LANG_MISSING_DATA || langRes == TextToSpeech.LANG_NOT_SUPPORTED) {
                        nativeTts?.setLanguage(Locale.SIMPLIFIED_CHINESE)
                    }
                    nativeTtsReady = true
                    nativeTts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) {}
                        override fun onDone(utteranceId: String?) {
                            runOnUiThread {
                                channelInstance?.invokeMethod("onTtsComplete", utteranceId)
                            }
                        }
                        override fun onError(utteranceId: String?) {
                            runOnUiThread {
                                channelInstance?.invokeMethod("onTtsError", utteranceId)
                            }
                        }
                    })
                }
            }
        }
    }

    override fun onDestroy() {
        try {
            nativeTts?.stop()
            nativeTts?.shutdown()
            nativeTts = null
            mediaPlayer?.release()
            mediaPlayer = null
        } catch (e: Exception) {}
        super.onDestroy()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumeKeyScrollEnabled) {
            if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                channelInstance?.invokeMethod("onVolumeScroll", "down")
                return true
            } else if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                channelInstance?.invokeMethod("onVolumeScroll", "up")
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun saveFileToDownloads(sourcePath: String, fileName: String, mimeType: String): Boolean {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+ 使用 MediaStore (Scoped Storage)
                val contentValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/fanqie")
                    put(MediaStore.MediaColumns.IS_PENDING, 1) // 标记为处理中
                }
                
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                
                uri?.let {
                    resolver.openOutputStream(it)?.use { outputStream ->
                        FileInputStream(File(sourcePath)).use { inputStream ->
                            inputStream.copyTo(outputStream)
                        }
                    }
                    // 写入完成，清除 PENDING 标记
                    contentValues.clear()
                    contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    resolver.update(it, contentValues, null, null)
                    return true
                }
                return false
            } else {
                // Android 9及以下使用的是 Legacy Storage (需要 WRITE_EXTERNAL_STORAGE 权限)
                val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                val fanqieDir = File(downloadDir, "fanqie")
                if (!fanqieDir.exists()) {
                    if (!fanqieDir.mkdirs()) return false
                }
                
                val destFile = File(fanqieDir, fileName)
                FileInputStream(File(sourcePath)).use { input ->
                    destFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                return true
            }
        } catch (e: Exception) {
            e.printStackTrace()
            return false
        }
    }
}
