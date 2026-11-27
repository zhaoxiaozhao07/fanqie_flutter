package com.fanqie.fanqie_flutter

import android.content.ClipData
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.os.Bundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.WindowManager
import android.view.Window
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.KeyStore
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
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
    private val nativeSynthExecutor = Executors.newSingleThreadExecutor()
    private var nativeSynthTts: TextToSpeech? = null
    private var nativeSynthReady = false
    private val nativeSynthLock = Any()
    private val externalImportLock = Any()
    private val externalImportInbox = mutableListOf<Map<String, Any?>>()
    private val externalImportFiles = mutableMapOf<String, File>()
    private var externalImportsInFlight = 0
    private val shortcutLock = Any()
    private val pendingShortcuts = mutableListOf<Map<String, Any?>>()
    const val ACTION_READER_SHORTCUT = "com.fanqie.fanqie_flutter.action.SHORTCUT"
    const val EXTRA_SHORTCUT_ACTION = "shortcut_action"
    const val EXTRA_BOOK_ID = "book_id"
    var volumeKeyScrollEnabled = false

    /// 接收图标长按快捷方式或桌面小组件点击事件并通知 Flutter 层直达目标功能
    fun handleShortcutIntent(action: String, bookId: String?) {
        val payload = mapOf("action" to action, "bookId" to bookId)
        synchronized(shortcutLock) {
            pendingShortcuts.add(payload)
        }
        emit("onShortcutAction", payload)
    }

    /// 处理外部文件管理器/微信/QQ 通过 ACTION_VIEW 打开的 TXT 或 EPUB 文件
    fun handleExternalIntent(context: Context, intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        val app = context.applicationContext
        synchronized(externalImportLock) { externalImportsInFlight++ }
        files.execute {
            val id = "android_ext_${UUID.randomUUID()}"
            try {
                val displayName = resolveIntentDisplayName(app, uri, intent.type)
                val lower = displayName.lowercase(Locale.ROOT)
                val ext = when {
                    lower.endsWith(".epub") -> ".epub"
                    lower.endsWith(".txt") -> ".txt"
                    intent.type == "application/epub+zip" -> ".epub"
                    intent.type?.startsWith("text/") == true -> ".txt"
                    else -> ""
                }
                if (ext.isEmpty()) {
                    enqueueExternalImport(mapOf(
                        "id" to id,
                        "name" to displayName,
                        "path" to null,
                        "error" to "暂仅支持打开 TXT 或 EPUB 小说文件"
                    ), null)
                    return@execute
                }
                val safeName = if (lower.endsWith(ext)) displayName else "$displayName$ext"
                val dir = File(app.cacheDir, "external_imports").apply { mkdirs() }
                val target = File(dir, "${id}_${safeName.replace(Regex("[^A-Za-z0-9._\\-\\u4e00-\\u9fa5]"), "_")}")
                val maxBytes = 128L * 1024L * 1024L
                var total = 0L
                val input = app.contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("无法读取外部文件内容")
                input.use { src ->
                    target.outputStream().use { dst ->
                        val buffer = ByteArray(16384)
                        while (true) {
                            val read = src.read(buffer)
                            if (read <= 0) break
                            total += read
                            if (total > maxBytes) {
                                throw IllegalStateException("文件超过 128 MB 限制")
                            }
                            dst.write(buffer, 0, read)
                        }
                    }
                }
                if (total <= 0L) {
                    target.delete()
                    throw IllegalStateException("外部文件内容为空")
                }
                enqueueExternalImport(mapOf(
                    "id" to id,
                    "name" to safeName,
                    "path" to target.absolutePath,
                    "error" to null
                ), target)
            } catch (e: Exception) {
                enqueueExternalImport(mapOf(
                    "id" to id,
                    "name" to "外部小说",
                    "path" to null,
                    "error" to (e.message ?: "无法读取外部文件")
                ), null)
            } finally {
                synchronized(externalImportLock) {
                    externalImportsInFlight = (externalImportsInFlight - 1).coerceAtLeast(0)
                }
                emit("onExternalImportsAvailable")
            }
        }
    }

    private fun resolveIntentDisplayName(context: Context, uri: Uri, mimeType: String?): String {
        if (uri.scheme == "content") {
            try {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val name = c.getString(0)
                        if (!name.isNullOrBlank()) return File(name).name
                    }
                }
            } catch (_: Exception) {}
        }
        val segment = uri.lastPathSegment?.let { File(it).name }
        if (!segment.isNullOrBlank()) return segment
        return if (mimeType == "application/epub+zip") "import.epub" else "import.txt"
    }

    private fun enqueueExternalImport(entry: Map<String, Any?>, file: File?) {
        synchronized(externalImportLock) {
            externalImportInbox.add(entry)
            val id = entry["id"] as? String
            if (id != null && file != null) {
                externalImportFiles[id] = file
            }
        }
    }

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
                    "readTtsSecret" -> {
                        files.execute {
                            val secret = ReaderSecrets.read(app)
                            main.post { result.success(secret) }
                        }
                    }
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
                            "fileImport" to true,
                            "ttsEngines" to engines.size,
                            "sdk" to Build.VERSION.SDK_INT,
                            "foreground" to (activity?.get()?.hasWindowFocus() == true),
                            "windowBrightness" to (activity?.get()?.window?.attributes?.screenBrightness ?: -1f),
                            "interactive" to (app.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager).isInteractive
                        ))
                    }
                    "takeExternalImports" -> {
                        val items = synchronized(externalImportLock) {
                            val copy = externalImportInbox.toList()
                            externalImportInbox.clear()
                            copy
                        }
                        result.success(items)
                    }
                    "releaseExternalImport" -> {
                        val id = call.argument<String>("id") ?: ""
                        val file = synchronized(externalImportLock) { externalImportFiles.remove(id) }
                        if (file != null) {
                            files.execute { try { file.delete() } catch (_: Exception) {} }
                        }
                        result.success(true)
                    }
                    "externalImportsBusy" -> {
                        val busy = synchronized(externalImportLock) {
                            externalImportsInFlight > 0 || externalImportInbox.isNotEmpty()
                        }
                        result.success(busy)
                    }
                    "getNativeTtsVoices" -> {
                        nativeSynthExecutor.execute {
                            val voices = listNativeTtsVoices(app)
                            main.post { result.success(voices) }
                        }
                    }
                    "writeTtsSecret" -> {
                        val value = call.argument<String>("value") ?: ""
                        files.execute {
                            val ok = ReaderSecrets.write(app, value)
                            main.post { result.success(ok) }
                        }
                    }
                    "readNamedSecret" -> {
                        val keyName = call.argument<String>("key") ?: ""
                        if (keyName.isBlank()) {
                            result.success(null)
                        } else {
                            files.execute {
                                val value = ReaderSecrets.readNamed(app, keyName)
                                main.post { result.success(value) }
                            }
                        }
                    }
                    "writeNamedSecret" -> {
                        val keyName = call.argument<String>("key") ?: ""
                        val value = call.argument<String>("value") ?: ""
                        if (keyName.isBlank()) {
                            result.success(false)
                        } else {
                            files.execute {
                                val ok = ReaderSecrets.writeNamed(app, keyName, value)
                                main.post { result.success(ok) }
                            }
                        }
                    }
                    "probeAudioDuration" -> {
                        val filePath = call.argument<String>("filePath") ?: ""
                        files.execute {
                            val probed = probeAudioDuration(filePath)
                            main.post { result.success(probed) }
                        }
                    }
                    "getFreeDiskBytes" -> {
                        val dirPath = call.argument<String>("path") ?: app.filesDir.absolutePath
                        files.execute {
                            val free = getFreeDiskBytes(dirPath)
                            main.post { result.success(free) }
                        }
                    }
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
                    "getAndroidSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "isIgnoringBatteryOptimizations" -> {
                        val ignoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
                            pm.isIgnoringBatteryOptimizations(app.packageName)
                        } else {
                            true
                        }
                        result.success(ignoring)
                    }
                    "openBatteryOptimizationSettings" -> {
                        val opened = openBatteryOptimizationSettings(app)
                        result.success(opened)
                    }
                    "shareImageFile" -> {
                        val filePath = call.argument<String>("filePath") ?: ""
                        val text = call.argument<String>("text")
                        val title = call.argument<String>("title") ?: "分享金句卡片"
                        val shared = shareImageFile(app, filePath, text, title)
                        result.success(shared)
                    }
                    "takePendingShortcuts" -> {
                        val list = synchronized(shortcutLock) {
                            val copy = pendingShortcuts.toList()
                            pendingShortcuts.clear()
                            copy
                        }
                        result.success(list)
                    }
                    "updateHomeWidget" -> {
                        val bookId = call.argument<String>("bookId") ?: ""
                        val bookName = call.argument<String>("bookName") ?: ""
                        val chapterTitle = call.argument<String>("chapterTitle") ?: ""
                        val progressText = call.argument<String>("progressText") ?: ""
                        ReaderAppWidgetProvider.saveAndRefresh(
                            app,
                            bookId = bookId,
                            bookName = bookName,
                            chapterTitle = chapterTitle,
                            progressText = progressText
                        )
                        result.success(true)
                    }
                    "synthesizeNativeTtsToFile" -> {
                        val text = call.argument<String>("text") ?: ""
                        val rate = (call.argument<Number>("rate")?.toFloat() ?: 1.0f).coerceIn(0.5f, 2.0f)
                        val voiceId = call.argument<String>("voiceId") ?: ""
                        val outputPath = call.argument<String>("outputPath") ?: ""
                        nativeSynthExecutor.execute {
                            val res = synthesizeNativeTtsToFile(app, text, rate, voiceId, outputPath)
                            main.post { result.success(res) }
                        }
                    }
                    "initNativeTts", "speakNativeTts", "playAudioFile", "preloadNextAudio", "clearPreloadedAudio", "pauseAudio", "resumeAudio",
                    "stopNativeTts", "stopAudio", "stopPlayback", "setAudioVolume", "seekAudio", "setSleepDeadline",
                    "updateMediaPlaybackState", "releasePlaybackService", "getPlaybackState",
                    "setPlaybackRate", "getAudioPosition" -> {
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

    /// 枚举设备系统 TextToSpeech 已安装的可用发音人（中文优先排序）
    private fun listNativeTtsVoices(context: Context): List<Map<String, String>> {
        synchronized(nativeSynthLock) {
            if (!nativeSynthReady || nativeSynthTts == null) {
                val initLatch = CountDownLatch(1)
                var initStatus = TextToSpeech.ERROR
                var engine: TextToSpeech? = null
                main.post {
                    engine = TextToSpeech(context) { status ->
                        initStatus = status
                        initLatch.countDown()
                    }
                }
                if (!initLatch.await(8, TimeUnit.SECONDS) || initStatus != TextToSpeech.SUCCESS || engine == null) {
                    try { engine?.shutdown() } catch (_: Exception) {}
                    return emptyList()
                }
                val ttsInstance = engine!!
                val langResult = ttsInstance.setLanguage(Locale.SIMPLIFIED_CHINESE)
                if (langResult == TextToSpeech.LANG_MISSING_DATA || langResult == TextToSpeech.LANG_NOT_SUPPORTED) {
                    ttsInstance.setLanguage(Locale.getDefault())
                }
                nativeSynthTts = ttsInstance
                nativeSynthReady = true
            }
            val tts = nativeSynthTts ?: return emptyList()
            val allVoices = try { tts.voices?.toList().orEmpty() } catch (_: Exception) { emptyList() }
            return allVoices
                .filter { !it.isNetworkConnectionRequired && (it.locale.language == "zh" || it.locale.language == Locale.getDefault().language) }
                .sortedWith(compareBy<android.speech.tts.Voice>({ it.locale.language != "zh" }, { it.name }))
                .take(30)
                .map { v ->
                    mapOf(
                        "id" to v.name,
                        "name" to v.name,
                        "language" to v.locale.toLanguageTag()
                    )
                }
        }
    }

    /// 将文本通过 Android 系统 TextToSpeech 离线合成为 WAV 音频文件，供沉浸式多角色听书旁白/角色无缝复用
    private fun synthesizeNativeTtsToFile(
        context: Context,
        text: String,
        rate: Float,
        voiceId: String,
        outputPath: String
    ): Map<String, Any?> {
        if (text.isBlank() || outputPath.isBlank()) {
            return mapOf("ok" to false, "error" to "待合成文本或输出路径为空")
        }
        val outFile = File(outputPath)
        outFile.parentFile?.mkdirs()
        if (outFile.exists()) outFile.delete()

        synchronized(nativeSynthLock) {
            if (!nativeSynthReady || nativeSynthTts == null) {
                val initLatch = CountDownLatch(1)
                var initStatus = TextToSpeech.ERROR
                var engine: TextToSpeech? = null
                main.post {
                    engine = TextToSpeech(context) { status ->
                        initStatus = status
                        initLatch.countDown()
                    }
                }
                if (!initLatch.await(12, TimeUnit.SECONDS) || initStatus != TextToSpeech.SUCCESS || engine == null) {
                    try { engine?.shutdown() } catch (_: Exception) {}
                    return mapOf("ok" to false, "error" to "系统语音引擎初始化失败，请检查设备已安装中文 TTS 语音包")
                }
                val ttsInstance = engine!!
                val langResult = ttsInstance.setLanguage(Locale.SIMPLIFIED_CHINESE)
                if (langResult == TextToSpeech.LANG_MISSING_DATA || langResult == TextToSpeech.LANG_NOT_SUPPORTED) {
                    ttsInstance.setLanguage(Locale.getDefault())
                }
                nativeSynthTts = ttsInstance
                nativeSynthReady = true
            }

            val tts = nativeSynthTts
                ?: return mapOf("ok" to false, "error" to "系统语音引擎不可用")

            try {
                if (voiceId.isNotBlank() && voiceId != "default") {
                    val matched = tts.voices?.firstOrNull { it.name == voiceId }
                    if (matched != null) {
                        tts.voice = matched
                    }
                } else {
                    tts.setLanguage(Locale.SIMPLIFIED_CHINESE)
                }
                tts.setSpeechRate(rate.coerceIn(0.5f, 2.0f))

                val utteranceId = "immersive_native_${UUID.randomUUID()}"
                val doneLatch = CountDownLatch(1)
                var succeeded = false
                var failureReason: String? = null
                tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(id: String?) {}
                    override fun onDone(id: String?) {
                        if (id == utteranceId) {
                            succeeded = true
                            doneLatch.countDown()
                        }
                    }
                    @Deprecated("Android legacy callback")
                    override fun onError(id: String?) {
                        if (id == utteranceId) {
                            failureReason = "系统语音合成失败"
                            doneLatch.countDown()
                        }
                    }
                    override fun onError(id: String?, errorCode: Int) {
                        if (id == utteranceId) {
                            failureReason = "系统语音合成失败（错误码 $errorCode）"
                            doneLatch.countDown()
                        }
                    }
                })

                val accepted = tts.synthesizeToFile(text, Bundle(), outFile, utteranceId)
                if (accepted != TextToSpeech.SUCCESS) {
                    return mapOf("ok" to false, "error" to "系统语音引擎拒绝合成请求")
                }
                if (!doneLatch.await(25, TimeUnit.SECONDS)) {
                    tts.stop()
                    return mapOf("ok" to false, "error" to "系统语音合成超时")
                }
                if (!succeeded || !outFile.isFile || outFile.length() <= 44L) {
                    return mapOf("ok" to false, "error" to (failureReason ?: "系统语音输出音频为空"))
                }
                return mapOf("ok" to true, "filePath" to outFile.absolutePath)
            } catch (e: Exception) {
                return mapOf("ok" to false, "error" to "系统语音合成异常：${e.message ?: "未知错误"}")
            }
        }
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

    /// 通过 Android 原生 MediaMetadataRetriever 校验音频可解码并返回真实时长毫秒数
    private fun probeAudioDuration(filePath: String): Map<String, Any?> {
        if (filePath.isBlank()) return mapOf("valid" to false, "durationMs" to 0)
        val file = File(filePath)
        if (!file.isFile || file.length() <= 0L) return mapOf("valid" to false, "durationMs" to 0)
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            val durStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            val mime = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE) ?: ""
            val hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
            val durationMs = durStr?.toLongOrNull() ?: 0L
            val valid = durationMs > 0L && (hasAudio == null || hasAudio == "yes" || mime.startsWith("audio/"))
            mapOf(
                "valid" to valid,
                "durationMs" to durationMs.coerceAtLeast(0L),
                "mime" to mime
            )
        } catch (_: Exception) {
            mapOf("valid" to false, "durationMs" to 0)
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    /// 获取目标路径所在文件系统的真实剩余磁盘空间字节数
    private fun getFreeDiskBytes(dirPath: String): Long {
        return try {
            var target = File(dirPath)
            while (!target.exists() && target.parentFile != null) {
                target = target.parentFile!!
            }
            val stat = StatFs(target.absolutePath)
            stat.availableBytes
        } catch (_: Exception) {
            -1L
        }
    }

    /// 打开系统电池优化设置页（失败时降级至应用详情页，引导用户允许后台高耗电/无限制运行）
    private fun openBatteryOptimizationSettings(context: Context): Boolean {
        val host = activity?.get()
        val intents = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                add(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
            add(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", context.packageName, null)
                }
            )
        }
        for (intent in intents) {
            try {
                if (host != null) {
                    host.startActivity(intent)
                } else {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                }
                return true
            } catch (_: Exception) {
                // 尝试下一候选设置页
            }
        }
        return false
    }

    /// 通过 FileProvider 将生成的金句海报 PNG 分享至微信/QQ/系统分享面板
    private fun shareImageFile(
        context: Context,
        filePath: String,
        text: String?,
        title: String
    ): Boolean {
        val file = File(filePath)
        if (!file.isFile || file.length() <= 0L) return false
        return try {
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file
            )
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                if (!text.isNullOrBlank()) {
                    putExtra(Intent.EXTRA_TEXT, text)
                }
                clipData = ClipData.newUri(context.contentResolver, title, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(sendIntent, title).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val host = activity?.get()
            if (host != null) {
                host.startActivity(chooser)
            } else {
                chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(chooser)
            }
            true
        } catch (_: Exception) {
            false
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
    fun write(context: Context, text: String): Boolean = writeNamed(context, "tts", text)
    fun read(context: Context): String? = readNamed(context, "tts")
    fun writeNamed(context: Context, slot: String, text: String): Boolean {
        val prefs = context.getSharedPreferences("reader_secure", Context.MODE_PRIVATE)
        if (text.isEmpty()) return prefs.edit().remove(slot).commit()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(text.toByteArray(Charsets.UTF_8))
        return prefs.edit().putString(slot, "${Base64.encodeToString(cipher.iv, Base64.NO_WRAP)}:${Base64.encodeToString(encrypted, Base64.NO_WRAP)}").commit()
    }
    fun readNamed(context: Context, slot: String): String? {
        val prefs = context.getSharedPreferences("reader_secure", Context.MODE_PRIVATE)
        val value = prefs.getString(slot, null) ?: return null
        return try {
            val parts = value.split(':')
            if (parts.size != 2) {
                prefs.edit().remove(slot).apply()
                return null
            }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
            String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (_: Exception) {
            // 密钥库失效或密文损坏时清理损坏槽位并安全回退，避免持续崩溃
            prefs.edit().remove(slot).apply()
            null
        }
    }
}
