package com.kinflow.kinflow

import android.app.Application
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileWriter
import kotlin.jvm.Synchronized

class KinflowApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val message = buildString {
                    append("[Native ").append(System.currentTimeMillis()).append("]\n")
                    append("Thread: ").append(thread.name).append("\n")
                    append("Exception: ").append(throwable).append("\n")
                    throwable.stackTrace?.forEach { append("  at ").append(it).append("\n") }
                    append("\n")
                }
                appendTextToDownloads("kinflow_native_crash.log", message)
            } catch (_: Exception) {
            }
            Thread.getDefaultUncaughtExceptionHandler()
                ?.uncaughtException(thread, throwable)
        }
    }

    @Synchronized
    fun appendTextToDownloads(fileName: String, text: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            if (uri != null) {
                resolver.openOutputStream(uri)?.use { out ->
                    val existing = runCatching { resolver.openInputStream(uri)?.readBytes() }
                        .getOrNull()?.takeIf { it.isNotEmpty() }
                    existing?.let { out.write(it) }
                    out.write(text.toByteArray())
                }
            }
        } else {
            val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            if (dir != null) {
                dir.mkdirs()
                FileWriter(File(dir, fileName), true).use { it.write(text) }
            }
        }
        val backupDir = File(
            Environment.getExternalStorageDirectory(),
            "Android/data/${packageName}/files"
        )
        backupDir.mkdirs()
        FileWriter(File(backupDir, fileName), true).use { it.write(text) }
    }
}
