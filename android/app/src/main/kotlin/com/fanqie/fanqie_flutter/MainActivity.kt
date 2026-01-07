package com.fanqie.fanqie_flutter

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.fanqie.fanqie_flutter/download"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
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
            } else {
                result.notImplemented()
            }
        }
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
