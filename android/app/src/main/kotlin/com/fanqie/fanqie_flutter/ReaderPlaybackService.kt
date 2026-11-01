package com.fanqie.fanqie_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.MediaPlayer
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

/** Native audio owner. All callbacks include the Dart playback token. */
class ReaderPlaybackService : Service() {
    companion object {
        private const val CHANNEL = "reader_playback"
        private const val NOTIFICATION = 320
        private var instance: ReaderPlaybackService? = null
        private data class Command(val method: String, val args: Map<String, Any?>, val result: MethodChannel.Result)
        private val pending = mutableListOf<Command>()

        fun dispatch(context: Context, method: String, args: Map<String, Any?>, result: MethodChannel.Result) {
            instance?.let { it.command(method, args, result); return }
            if (method == "getPlaybackState") {
                result.success(mapOf("active" to false, "playing" to false))
                return
            }
            val starts = method == "speakNativeTts" || method == "playAudioFile" ||
                (method == "updateMediaPlaybackState" && args["isActive"] == true)
            if (!starts && pending.isEmpty()) {
                result.success(method != "resumeAudio")
                return
            }
            pending.add(Command(method, args, result))
            if (pending.size == 1) {
                try {
                    val intent = Intent(context, ReaderPlaybackService::class.java)
                    if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
                } catch (_: Exception) {
                    val failed = pending.toList(); pending.clear()
                    failed.forEach { it.result.error("AUDIO_SERVICE", "无法启动听书服务，请在应用前台重试", null) }
                }
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var session: MediaSession
    private lateinit var audio: AudioManager
    private lateinit var wakeLock: PowerManager.WakeLock
    private var focusRequest: AudioFocusRequest? = null
    private var focusGeneration = 0
    private var legacyFocusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var player: MediaPlayer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var currentId: String? = null
    private var nativeAudio = false
    private var speechFile: File? = null
    private var pendingStart: MethodChannel.Result? = null
    private var pendingSpeech: (() -> Unit)? = null
    private var playing = false
    private var volume = 1f
    private var deadline = 0L
    private var title = "听书"
    private var subtitle = "准备播放"

    private fun focusListener(generation: Int) = AudioManager.OnAudioFocusChangeListener { change ->
        if (generation == focusGeneration &&
            (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)) {
            val id = currentId
            pauseOutput()
            ReaderRuntime.emit("onAudioFocusLost", mapOf("id" to id))
        }
        // Focus gain does not auto-play: the user explicitly resumes.
    }
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                pauseOutput()
                ReaderRuntime.emit("onAudioBecomingNoisy")
            }
        }
    }
    private val sleepTick = object : Runnable {
        override fun run() {
            if (deadline <= 0) return
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) {
                val expired = deadline
                stopPlayback()
                ReaderRuntime.emit("onAudioSleepTimer", mapOf("deadline" to expired))
                main.postDelayed({
                    if (deadline == expired && currentId == null) stopSelf()
                }, 500)
            } else {
                if (remaining <= 10000) setVolume((remaining / 10000f).coerceIn(0f, 1f))
                main.postDelayed(this, minOf(1000L, remaining))
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "fanqie:reader-playback").apply { setReferenceCounted(false) }
        if (Build.VERSION.SDK_INT >= 26) {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
                NotificationChannel(CHANNEL, "听书播放", NotificationManager.IMPORTANCE_LOW))
        }
        session = MediaSession(this, "FanqieReader").apply {
            @Suppress("DEPRECATION")
            setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { ReaderRuntime.emit("onMediaPlay") }
                override fun onPause() { pauseOutput(); ReaderRuntime.emit("onMediaPause") }
                override fun onSkipToNext() { ReaderRuntime.emit("onMediaNext") }
                override fun onSkipToPrevious() { ReaderRuntime.emit("onMediaPrev") }
                override fun onStop() { stopPlayback(); ReaderRuntime.emit("onMediaStop"); stopSelf() }
            })
            isActive = true
        }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") registerReceiver(noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        startForeground(NOTIFICATION, notification())
        // Remove abandoned synthesized audio from a previous process, not user files.
        cacheDir.listFiles()?.filter { it.name.startsWith("reader-tts-") && it.extension == "wav" }?.forEach { it.delete() }
        val commands = pending.toList(); pending.clear()
        commands.forEach { command(it.method, it.args, it.result) }
    }

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "play" -> ReaderRuntime.emit("onMediaPlay")
            "pause" -> { pauseOutput(); ReaderRuntime.emit("onMediaPause") }
            "next" -> ReaderRuntime.emit("onMediaNext")
            "previous" -> ReaderRuntime.emit("onMediaPrev")
            "stop" -> { stopPlayback(); ReaderRuntime.emit("onMediaStop"); stopSelf() }
        }
        return START_NOT_STICKY
    }

    private fun command(method: String, args: Map<String, Any?>, result: MethodChannel.Result) {
        try {
            when (method) {
                "getPlaybackState" -> result.success(mapOf(
                    "active" to true,
                    "playing" to (player?.isPlaying == true),
                    "id" to currentId,
                    "volume" to volume,
                    "deadline" to deadline,
                    "native" to nativeAudio
                ))
                "speakNativeTts" -> startSpeech(args, result)
                "playAudioFile" -> {
                    stopPlayback()
                    val id = args["id"] as? String ?: throw IllegalArgumentException()
                    currentId = id; nativeAudio = false; pendingStart = result
                    if (!requestFocus()) { finishStart(id, false); return }
                    prepareAudio(File(args["filePath"] as? String ?: ""), id)
                }
                "stopPlayback" -> result.success(stopPlayback(args["id"] as? String))
                "stopNativeTts" -> { if (nativeAudio) stopPlayback(); result.success(true) }
                "stopAudio" -> { if (!nativeAudio) stopPlayback(); result.success(true) }
                "pauseAudio" -> {
                    if (args["id"] != null && args["id"] != currentId) result.success(false)
                    else { pauseOutput(); result.success(true) }
                }
                "resumeAudio" -> {
                    if (args["id"] != currentId || player == null || !requestFocus()) result.success(false)
                    else { player!!.start(); playing = true; updateNotification(); result.success(true) }
                }
                "setAudioVolume" -> { setVolume((args["volume"] as? Number)?.toFloat() ?: 1f); result.success(true) }
                "setSleepDeadline" -> {
                    deadline = (args["milliseconds"] as? Number)?.toLong() ?: 0L
                    main.removeCallbacks(sleepTick)
                    if (deadline > 0) main.post(sleepTick)
                    result.success(true)
                }
                "updateMediaPlaybackState" -> {
                    title = args["title"] as? String ?: "听书"
                    subtitle = args["subtitle"] as? String ?: ""
                    playing = args["isPlaying"] == true
                    updateNotification()
                    result.success(true)
                }
                "releasePlaybackService" -> { stopPlayback(); result.success(true); stopSelf() }
                "initNativeTts" -> result.success(true)
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            if (pendingStart === result) pendingStart = null
            result.error("AUDIO_PLAYBACK", "音频操作失败，请检查语音引擎和输出设备", null)
        }
    }

    private fun startSpeech(args: Map<String, Any?>, result: MethodChannel.Result) {
        stopPlayback()
        val id = args["id"] as? String ?: throw IllegalArgumentException()
        val text = args["text"] as? String ?: ""
        currentId = id; nativeAudio = true; pendingStart = result
        if (text.isBlank() || !requestFocus()) { finishStart(id, false); return }
        val speak = {
            if (id == currentId) {
                val file = File.createTempFile("reader-tts-", ".wav", cacheDir)
                speechFile = file
                tts!!.setSpeechRate(((args["rate"] as? Number)?.toFloat() ?: 1f).coerceIn(.5f, 2f))
                val accepted = tts!!.synthesizeToFile(text, Bundle(), file, id)
                if (accepted != TextToSpeech.SUCCESS) finishStart(id, false)
            }
        }
        if (ttsReady) { speak(); return }
        pendingSpeech = speak
        if (tts != null) return
        tts = TextToSpeech(applicationContext) { status ->
            main.post {
                if (instance !== this) return@post
                if (status != TextToSpeech.SUCCESS) {
                    currentId?.let { finishStart(it, false) }
                    tts?.shutdown(); tts = null
                    return@post
                }
                val lang = tts!!.setLanguage(Locale.SIMPLIFIED_CHINESE)
                if (lang == TextToSpeech.LANG_MISSING_DATA || lang == TextToSpeech.LANG_NOT_SUPPORTED) {
                    currentId?.let { finishStart(it, false) }
                    tts?.shutdown(); tts = null
                    return@post
                }
                ttsReady = true
                tts!!.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) {
                        main.post {
                            if (utteranceId == currentId && utteranceId != null) {
                                val file = speechFile
                                if (file != null) prepareAudio(file, utteranceId)
                            }
                        }
                    }
                    @Deprecated("Android legacy callback")
                    override fun onError(utteranceId: String?) {
                        main.post {
                            if (utteranceId == currentId && utteranceId != null) {
                                finishStart(utteranceId, false)
                                ReaderRuntime.emit("onTtsError", mapOf("id" to utteranceId))
                            }
                        }
                    }
                })
                val pending = pendingSpeech; pendingSpeech = null; pending?.invoke()
            }
        }
    }

    private fun prepareAudio(file: File, id: String) {
        try {
        if (id != currentId) return
        if (!file.isFile || file.length() == 0L) { finishStart(id, false); return }
        val media = MediaPlayer()
        player = media
        media.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        media.setWakeMode(applicationContext, PowerManager.PARTIAL_WAKE_LOCK)
        media.setDataSource(file.absolutePath)
        media.setOnPreparedListener {
            if (currentId != id || player !== media) return@setOnPreparedListener
            try {
                media.setVolume(volume, volume)
                media.start(); playing = true
                finishStart(id, true)
                updateNotification()
            } catch (_: Exception) {
                finishStart(id, false)
                ReaderRuntime.emit("onAudioError", mapOf("id" to id))
            }
        }
        media.setOnCompletionListener {
            if (id == currentId) {
                playing = false
                ReaderRuntime.emit(if (nativeAudio) "onTtsComplete" else "onAudioComplete", mapOf("id" to id))
            }
        }
        media.setOnErrorListener { _, _, _ ->
            if (id == currentId) {
                finishStart(id, false)
                ReaderRuntime.emit(if (nativeAudio) "onTtsError" else "onAudioError", mapOf("id" to id))
            }
            true
        }
        media.prepareAsync()
        } catch (_: Exception) {
            finishStart(id, false)
            ReaderRuntime.emit("onAudioError", mapOf("id" to id))
        }
    }

    private fun finishStart(id: String, success: Boolean) {
        if (id != currentId) return
        val result = pendingStart; pendingStart = null
        result?.success(success)
    }
    private fun requestFocus(): Boolean {
        val listener = focusListener(++focusGeneration)
        wakeLock.acquire(300000L)
        val granted = if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener(listener, main).build()
            focusRequest = request
            audio.requestAudioFocus(request)
        } else {
            legacyFocusListener = listener
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        return granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }
    private fun abandonFocus() {
        ++focusGeneration
        if (Build.VERSION.SDK_INT >= 26) focusRequest?.let { audio.abandonAudioFocusRequest(it) }
        else legacyFocusListener?.let {
            @Suppress("DEPRECATION") audio.abandonAudioFocus(it)
        }
        focusRequest = null
        if (wakeLock.isHeld) wakeLock.release()
    }
    private fun pauseOutput() {
        try { if (player?.isPlaying == true) player?.pause() } catch (_: Exception) {}
        if (pendingStart != null) stopPlayback()
        playing = false
        abandonFocus()
        updateNotification()
    }
    private fun stopPlayback(expectedId: String? = null): Boolean {
        if (expectedId != null && expectedId != currentId) return false
        currentId = null
        pendingSpeech = null
        val result = pendingStart; pendingStart = null; result?.success(false)
        tts?.stop()
        try { player?.release() } catch (_: Exception) {}
        player = null
        speechFile?.delete(); speechFile = null
        playing = false
        abandonFocus()
        return true
    }
    private fun setVolume(value: Float) {
        volume = value.coerceIn(0f, 1f)
        try { player?.setVolume(volume, volume) } catch (_: Exception) {}
    }
    private fun action(name: String): PendingIntent = PendingIntent.getService(this, name.hashCode(),
        Intent(this, ReaderPlaybackService::class.java).setAction(name), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        val launch = packageManager.getLaunchIntentForPackage(packageName)!!
        return builder.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title).setContentText(subtitle).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_TRANSPORT).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .setDeleteIntent(action("stop"))
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_previous, "上一段", action("previous")).build())
            .addAction(Notification.Action.Builder(if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (playing) "暂停" else "继续", action(if (playing) "pause" else "play")).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_next, "下一段", action("next")).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "停止", action("stop")).build())
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1, 2))
            .build()
    }
    private fun updateNotification() {
        session.setMetadata(MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, subtitle).build())
        session.setPlaybackState(PlaybackState.Builder().setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_STOP)
            .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f).build())
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION, notification())
    }
    override fun onDestroy() {
        main.removeCallbacks(sleepTick)
        stopPlayback()
        tts?.shutdown(); tts = null
        session.isActive = false; session.release()
        try { unregisterReceiver(noisy) } catch (_: Exception) {}
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (instance === this) instance = null
        super.onDestroy()
    }
}
