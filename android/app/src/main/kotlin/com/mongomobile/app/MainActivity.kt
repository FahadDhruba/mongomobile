package com.mongomobile.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors

// local_auth needs a FragmentActivity to show the biometric prompt.
class MainActivity : FlutterFragmentActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var pendingCreate: MethodChannel.Result? = null
    private var pendingOpen: MethodChannel.Result? = null
    private val streams = HashMap<Int, Pair<Uri, OutputStream>>()
    private val inputs = HashMap<Int, InputStream>()
    private var nextStreamId = 1

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "com.mongomobile.app/files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "createDocument" -> createDocument(
                        call.argument<String>("name") ?: "export",
                        call.argument<String>("mimeType") ?: "application/octet-stream",
                        result,
                    )
                    "write" -> {
                        val id = call.argument<Int>("id")
                        val bytes = call.argument<ByteArray>("bytes")
                        val stream = streams[id]?.second
                        if (stream == null || bytes == null) {
                            result.error("closed", "The file is not open", null)
                        } else {
                            background(result) { stream.write(bytes); null }
                        }
                    }
                    "close" -> {
                        val entry = streams.remove(call.argument<Int>("id"))
                        if (entry == null) result.success(null)
                        else background(result) { entry.second.close(); null }
                    }
                    "abort" -> {
                        val entry = streams.remove(call.argument<Int>("id"))
                        if (entry == null) result.success(null)
                        else background(result) {
                            runCatching { entry.second.close() }
                            runCatching { DocumentsContract.deleteDocument(contentResolver, entry.first) }
                            null
                        }
                    }
                    "openDocument" -> openDocument(
                        call.argument<List<String>>("mimeTypes") ?: listOf("*/*"),
                        result,
                    )
                    "openRead" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) {
                            result.error("args", "No file", null)
                        } else {
                            val id = nextStreamId++
                            background(result) {
                                val stream = contentResolver.openInputStream(Uri.parse(uri))
                                    ?: throw IllegalStateException("Could not open the file")
                                synchronized(inputs) { inputs[id] = stream }
                                id
                            }
                        }
                    }
                    "read" -> {
                        val stream = synchronized(inputs) { inputs[call.argument<Int>("id")] }
                        if (stream == null) {
                            result.error("closed", "The file is not open", null)
                        } else {
                            background(result) {
                                val buffer = ByteArray(256 * 1024)
                                var filled = 0
                                while (filled < buffer.size) {
                                    val n = stream.read(buffer, filled, buffer.size - filled)
                                    if (n < 0) break
                                    filled += n
                                }
                                // Null marks the end of the file.
                                if (filled == 0) null else buffer.copyOf(filled)
                            }
                        }
                    }
                    "closeRead" -> {
                        val stream = synchronized(inputs) { inputs.remove(call.argument<Int>("id")) }
                        if (stream == null) result.success(null)
                        else background(result) { stream.close(); null }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, "com.mongomobile.app/browser")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("args", "No URL", null)
                        } else {
                            try {
                                startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("open", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, "com.mongomobile.app/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cacheDir" -> result.success(cacheDir.absolutePath)
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            packageManager.canRequestPackageInstalls()
                    )
                    "openInstallSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                )
                            )
                        }
                        result.success(null)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("args", "No APK path", null)
                        } else {
                            try {
                                val uri = FileProvider.getUriForFile(
                                    this, "$packageName.updates", File(path)
                                )
                                val intent = Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                            Intent.FLAG_ACTIVITY_NEW_TASK
                                    )
                                startActivity(intent)
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("install", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun createDocument(name: String, mimeType: String, result: MethodChannel.Result) {
        if (pendingCreate != null) {
            result.error("busy", "A save dialog is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, name)
        }
        pendingCreate = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_CREATE_DOCUMENT)
    }

    private fun openDocument(mimeTypes: List<String>, result: MethodChannel.Result) {
        if (pendingOpen != null) {
            result.error("busy", "A file picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
        }
        pendingOpen = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_OPEN_DOCUMENT)
    }

    /// The picked file's uri, display name and size (-1 when unknown).
    private fun describe(uri: Uri): Map<String, Any> {
        var name = uri.lastPathSegment ?: "file"
        var size = -1L
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val s = c.getColumnIndex(OpenableColumns.SIZE)
                if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
            }
        }
        return mapOf("uri" to uri.toString(), "name" to name, "size" to size)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_OPEN_DOCUMENT) {
            val result = pendingOpen ?: return
            pendingOpen = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                result.success(null)
            } else {
                background(result) { describe(uri) }
            }
            return
        }
        if (requestCode != REQUEST_CREATE_DOCUMENT) return
        val result = pendingCreate ?: return
        pendingCreate = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val stream = contentResolver.openOutputStream(uri, "wt")
                ?: throw IllegalStateException("Could not open the file")
            val id = nextStreamId++
            streams[id] = Pair(uri, stream)
            result.success(id)
        } catch (e: Exception) {
            result.error("open", e.message, null)
        }
    }

    /// Runs file IO off the main thread and answers on it.
    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("io", e.message, null) }
            }
        }
    }

    override fun onDestroy() {
        for ((_, entry) in streams) runCatching { entry.second.close() }
        streams.clear()
        synchronized(inputs) {
            for ((_, stream) in inputs) runCatching { stream.close() }
            inputs.clear()
        }
        io.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val REQUEST_CREATE_DOCUMENT = 4711
        private const val REQUEST_OPEN_DOCUMENT = 4712
    }
}
