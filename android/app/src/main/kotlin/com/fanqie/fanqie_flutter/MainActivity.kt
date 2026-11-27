package com.fanqie.fanqie_flutter

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.Display
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** The application-owned engine remains alive while the audio service runs. */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = ReaderRuntime.engine(context)
    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        ReaderRuntime.attach(this)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableHighRefreshRate()
        consumeExternalIntent(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeExternalIntent(intent)
    }

    /// 主动请求与当前分辨率匹配的最高屏幕刷新率（90Hz/120Hz/144Hz），提升翻页与滚动流畅度
    private fun enableHighRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val currentDisplay: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay
            }
            val activeMode = currentDisplay?.mode ?: return
            val bestMode = currentDisplay.supportedModes
                .filter {
                    it.physicalWidth == activeMode.physicalWidth &&
                        it.physicalHeight == activeMode.physicalHeight
                }
                .maxByOrNull { it.refreshRate } ?: return
            if (bestMode.modeId != activeMode.modeId && bestMode.refreshRate > activeMode.refreshRate) {
                val attrs = window.attributes
                attrs.preferredDisplayModeId = bestMode.modeId
                window.attributes = attrs
            }
        } catch (_: Exception) {
            // 部分设备或模拟器不支持自定义刷新率时静默保持默认模式
        }
    }

    private fun consumeExternalIntent(target: Intent?) {
        if (target == null) return
        if (target.action == Intent.ACTION_VIEW && target.data != null) {
            ReaderRuntime.handleExternalIntent(applicationContext, target)
            // 消费后重置意图，避免 Activity 重建时重复触发导入
            setIntent(Intent(Intent.ACTION_MAIN))
            return
        }
        if (target.action == ReaderRuntime.ACTION_READER_SHORTCUT) {
            val shortcutAction = target.getStringExtra(ReaderRuntime.EXTRA_SHORTCUT_ACTION)
            val bookId = target.getStringExtra(ReaderRuntime.EXTRA_BOOK_ID)
            if (!shortcutAction.isNullOrBlank()) {
                ReaderRuntime.handleShortcutIntent(shortcutAction, bookId)
                setIntent(Intent(Intent.ACTION_MAIN))
            }
        }
    }
    override fun onDestroy() {
        ReaderRuntime.detach(this)
        super.onDestroy()
    }
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (ReaderRuntime.volumeKeyScrollEnabled &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP)) {
            ReaderRuntime.emit("onVolumeScroll", if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) "down" else "up")
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}
