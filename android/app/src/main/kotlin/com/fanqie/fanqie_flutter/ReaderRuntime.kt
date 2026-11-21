package com.fanqie.fanqie_flutter

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
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
import android.view.Window
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
    private var brightnessWindow: WeakReference<Window>? = null
    private var originalBrightness: Float? = null
    private val main = Handler(Looper.getMainLooper())
    private val files = Executors.newSingleThreadExecutor()
    var volumeKeyScrollEnabled = false

    fun attach(value: MainActivity) { activity = WeakReference(value) }
    fun detach(value: MainActivity) {
        if (activity?.get() === value) {
            restoreBrightness()
            activity = null
        }
    }
    private fun restoreBrightness() {
        val window = brightnessWindow?.get()
        val original = originalBrightness
        if (window != null && original != null) {
            window.attributes = window.attributes.apply { screenBrightness = original }
        }
        brightnessWindow = null
        originalBrightness = null
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
                    "setReaderBrightness" -> {
                        val window = activity?.get()?.window
                        if (window == null) result.success(false)
                        else {
                            if (brightnessWindow?.get() !== window) {
                                originalBrightness = window.attributes.screenBrightness
                                brightnessWindow = WeakReference(window)
                            }
                            val value = (call.argument<Number>("value")?.toFloat() ?: -1f)
                            window.attributes = window.attributes.apply {
                                screenBrightness = if (value < 0) -1f else value.coerceIn(.05f, 1f)
                            }
                            result.success(true)
                        }
                    }
                    "restoreReaderBrightness" -> { restoreBrightness(); result.success(true) }
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
                    "normalizeTextFile" -> ReaderTextDecoder.normalize(
                        app, call.argument<String>("path") ?: "",
                        call.argument<String>("encoding") ?: "auto",
                        call.argument<String>("id") ?: "", result)
                    "cancelTextDecode" -> {
                        ReaderTextDecoder.cancel(call.argument<String>("id") ?: "")
                        result.success(true)
                    }
                    "getReaderCapabilities" -> {
                        val engines = app.packageManager.queryIntentServices(
                            android.content.Intent(android.speech.tts.TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
                        result.success(mapOf(
                            "mediaPlayback" to true,
                            "secureStorage" to true,
                            "ttsEngines" to engines.size,
                            "sdk" to Build.VERSION.SDK_INT,
                            "foreground" to (activity?.get()?.hasWindowFocus() == true),
                            "windowBrightness" to (activity?.get()?.window?.attributes?.screenBrightness ?: -1f),
                            "interactive" to (app.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager).isInteractive
                        ))
                    }
                    "writeTtsSecret" -> result.success(ReaderSecrets.write(app, call.argument<String>("value") ?: ""))
                    "saveToDownloads" -> {
                        val source = call.argument<String>("filePath") ?: ""
                        val name = File(call.argument<String>("fileName") ?: "export.txt").name
                        val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                        files.execute {
                            val saved = saveToDownloadsDetailed(app, source, name, mime)
                            main.post { result.success(saved["saved"] == true) }
                        }
                    }
                    "saveToDownloadsDetailed" -> {
                        val source = call.argument<String>("filePath") ?: ""
                        val name = File(call.argument<String>("fileName") ?: "export.txt").name
                        val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                        files.execute {
                            val saved = saveToDownloadsDetailed(app, source, name, mime)
                            main.post { result.success(saved) }
                        }
                    }
                    "checkDownloadedFile" -> {
                        val filePath = call.argument<String>("filePath") ?: ""
                        val contentUri = call.argument<String>("contentUri") ?: ""
                        files.execute {
                            val checked = checkDownloadedFile(app, filePath, contentUri)
                            main.post { result.success(checked) }
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

    /// 保存文件到 Android 公共下载目录 Download/fanqie，并返回真实路径、URI 与大小
    private fun saveToDownloadsDetailed(
        context: Context,
        source: String,
        name: String,
        mime: String
    ): Map<String, Any?> {
        try {
            val sourceFile = File(source)
            if (!sourceFile.isFile || sourceFile.length() <= 0L || name.isBlank() || name == "." || name == "..") {
                return mapOf("saved" to false, "error" to "待保存的源文件不存在")
            }
            val size = sourceFile.length()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val resolver = context.contentResolver
                val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/fanqie/"

                // Let MediaStore choose a collision-safe name. Never delete an old export.
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: return mapOf("saved" to false, "error" to "MediaStore 创建下载记录失败")
                var actualName: String? = null
                try {
                    val output = resolver.openOutputStream(uri)
                        ?: throw IllegalStateException("无法打开下载输出流")
                    val copied = output.use { stream -> sourceFile.inputStream().use { it.copyTo(stream) } }
                    if (copied != size) throw IllegalStateException("下载复制不完整")
                    values.clear()
                    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    if (resolver.update(uri, values, null, null) != 1) {
                        throw IllegalStateException("无法发布下载文件")
                    }
                } catch (error: Exception) {
                    try {
                        resolver.delete(uri, null, null)
                    } catch (_: Exception) {}
                    throw error
                }
                // Publication committed the export. Optional metadata errors
                // must never enter the copy/publication rollback path.
                try {
                    // 回查实际落盘文件名，防止系统在冲突时自动重命名为 xxx (1).epub
                    resolver.query(
                        uri,
                        arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                        null,
                        null,
                        null
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val queried = cursor.getString(0)
                            if (!queried.isNullOrBlank()) {
                                actualName = queried
                            }
                        }
                    }
                } catch (_: Exception) {}
                // A basename cannot establish the storage volume or Android
                // user/profile location. Return the known authoritative URI.
                return mapOf(
                    "saved" to true,
                    "path" to uri.toString(),
                    "uri" to uri.toString(),
                    "fileName" to actualName,
                    "size" to size
                )
            } else {
                @Suppress("DEPRECATION")
                val dir = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    "fanqie"
                )
                if (!dir.exists() && !dir.mkdirs()) {
                    return mapOf("saved" to false, "error" to "无法创建 Download/fanqie 目录")
                }
                val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
                val stem = name.substring(0, dot)
                val extension = name.substring(dot)
                var target: File? = null
                for (number in 0..10000) {
                    val candidate = File(dir, if (number == 0) name else "$stem ($number)$extension")
                    if (candidate.createNewFile()) {
                        target = candidate
                        break
                    }
                }
                val created = target ?: throw IllegalStateException("下载同名文件过多")
                try {
                    val copied = sourceFile.inputStream().use { input ->
                        created.outputStream().use { input.copyTo(it) }
                    }
                    if (copied != size || created.length() != size) {
                        throw IllegalStateException("下载复制不完整")
                    }
                    return mapOf(
                        "saved" to true, "path" to created.absolutePath,
                        "uri" to null, "fileName" to created.name, "size" to size
                    )
                } catch (error: Exception) {
                    // This path was exclusively created by this attempt.
                    created.delete()
                    throw error
                }
            }
        } catch (error: Exception) {
            return mapOf("saved" to false, "error" to (error.message ?: error.toString()))
        }
    }

    /// 校验已下载文件是否真实存在（兼容 Android 10+ 分区存储与外部文件删除检测）
    private fun checkDownloadedFile(
        context: Context,
        filePath: String,
        contentUri: String
    ): Map<String, Any?> {
        // 1. 优先通过 content:// URI 打开文件描述符确认物理文件依然存在且可读
        if (contentUri.startsWith("content://")) {
            val verified = verifyContentUri(context, contentUri)
            return verified ?: mapOf("exists" to false, "size" to 0L)
        }
        if (filePath.startsWith("content://")) {
            val verified = verifyContentUri(context, filePath)
            return verified ?: mapOf("exists" to false, "size" to 0L)
        }

        // Only check the recorded absolute path; never search by title/name.
        if (filePath.isNotBlank() && !filePath.startsWith("content://")) {
            try {
                val file = File(filePath)
                if (file.isAbsolute && file.isFile && file.length() > 0L) {
                    return mapOf(
                        "exists" to true,
                        "size" to file.length(),
                        "path" to file.absolutePath
                    )
                }
            } catch (_: Exception) {}
        }

        return mapOf("exists" to false, "size" to 0L)
    }

    private fun verifyContentUri(context: Context, uriString: String): Map<String, Any?>? {
        return try {
            val uri = Uri.parse(uriString)
            context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
                val len = afd.length
                val actualSize = if (len > 0L) {
                    len
                } else {
                    afd.parcelFileDescriptor.statSize
                }
                if (actualSize > 0L) {
                    mapOf("exists" to true, "size" to actualSize, "uri" to uriString)
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
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
