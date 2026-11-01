package com.fanqie.fanqie_flutter

import android.content.Context
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
