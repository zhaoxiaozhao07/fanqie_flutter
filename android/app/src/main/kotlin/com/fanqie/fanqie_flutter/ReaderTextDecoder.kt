package com.fanqie.fanqie_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.nio.charset.Charset
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Stream transcoding keeps GB18030/UTF-16 large books off the UI thread. */
object ReaderTextDecoder {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()

    fun cancel(id: String) { cancellations[id]?.set(true) }

    fun normalize(context: Context, path: String, requested: String, id: String, result: MethodChannel.Result) {
        if (requested !in setOf("auto", "UTF-8", "UTF-16LE", "UTF-16BE", "GB18030", "Big5")) {
            result.error("ENCODING", "不支持的文本编码", null); return
        }
        val cancelled = AtomicBoolean(false)
        cancellations[id] = cancelled
        executor.execute {
            var output: File? = null
            try {
                val source = File(path)
                require(source.isFile && source.length() in 1..(128L * 1024 * 1024))
                val header = ByteArray(4)
                source.inputStream().use { it.read(header) }
                var encoding = requested
                if (encoding == "auto") {
                    encoding = when {
                        header[0] == 0xff.toByte() && header[1] == 0xfe.toByte() -> "UTF-16LE"
                        header[0] == 0xfe.toByte() && header[1] == 0xff.toByte() -> "UTF-16BE"
                        else -> "UTF-8"
                    }
                }
                output = File.createTempFile("reader-decoded-", ".txt", context.cacheDir)
                try {
                    convert(source, output, encoding, cancelled)
                } catch (error: CharacterCodingException) {
                    if (requested != "auto" || encoding != "UTF-8") throw error
                    encoding = "GB18030"
                    convert(source, output, encoding, cancelled)
                }
                if (cancelled.get()) throw InterruptedException()
                val filePath = output.absolutePath
                val selected = encoding
                main.post { result.success(mapOf("path" to filePath, "encoding" to selected)) }
            } catch (_: InterruptedException) {
                output?.delete()
                main.post { result.error("IMPORT_CANCELLED", "导入已取消", null) }
            } catch (_: Exception) {
                output?.delete()
                main.post { result.error("TEXT_DECODE", "文本解码失败，请手动选择编码", null) }
            } finally {
                cancellations.remove(id)
            }
        }
    }

    private fun convert(source: File, output: File, name: String, cancelled: AtomicBoolean) {
        val decoder = Charset.forName(name).newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        InputStreamReader(source.inputStream(), decoder).use { input ->
            OutputStreamWriter(FileOutputStream(output, false), Charsets.UTF_8).use { target ->
                val buffer = CharArray(8192)
                var first = true
                while (true) {
                    if (cancelled.get()) throw InterruptedException()
                    val count = input.read(buffer)
                    if (count < 0) break
                    val start = if (first && count > 0 && buffer[0] == '\uFEFF') 1 else 0
                    first = false
                    target.write(buffer, start, count - start)
                }
            }
        }
    }
}
