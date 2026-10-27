package app.imagyn

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * Implements the `app.imagyn/media` channel declared in the Dart layer.
 *
 * `saveImage` writes one finished image into the shared `Pictures/Imagyn`
 * folder through MediaStore, so the file shows up in the system gallery. That
 * needs neither a storage permission nor root on API 29 and above, and it never
 * touches the private copy the app keeps for its own history.
 *
 * `saveFile` does the same for a generated deck in `Downloads/Imagyn`: a
 * presentation is not an image, and putting it in the gallery would hide it
 * from the file managers that know how to open a `.pptx`.
 */
class MainActivity : FlutterActivity() {
    private var pendingStorageSave: (() -> Unit)? = null
    private var pendingStorageResult: MethodChannel.Result? = null

    companion object {
        const val ENGINE_ID = "imagyn-engine"
        private const val CHANNEL = "app.imagyn/media"
        private const val BACKGROUND = "app.imagyn/background"
        private const val ALBUM = "Imagyn"
        private const val NOTIFICATION_REQUEST = 71
        private const val STORAGE_REQUEST = 72
        val SUPPORTED_TYPES = setOf("image/png", "image/jpeg", "image/webp")

        /** True while an activity is on screen; a turn only notifies otherwise. */
        @Volatile var visible = false
    }

    // The engine lives in the process, not in this activity: swiping the task
    // away detaches the view, and the turn keeps running while TurnService
    // holds the process. Reopening the app reattaches to the same isolate.
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        visible = true
    }

    override fun onPause() {
        visible = false
        super.onPause()
    }

    // No super call: ImagynApplication registers the plugins when it creates
    // the engine, and registering them again only logs duplicate-plugin errors.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> saveImage(call, result)
                    "saveFile" -> saveFile(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND)
            .setMethodCallHandler { call, result ->
                val title = call.argument<String>("title") ?: ""
                val body = call.argument<String>("body") ?: ""
                when (call.method) {
                    "start" -> {
                        askForNotifications()
                        TurnService.start(applicationContext, title, body)
                        result.success(null)
                    }
                    "stop" -> {
                        TurnService.stop(applicationContext)
                        result.success(null)
                    }
                    "notify" -> {
                        // A result the user is already looking at is not worth
                        // a notification.
                        if (!visible) TurnService.notify(applicationContext, title, body)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST,
        )
    }

    // API 24–28 writes the shared folders directly, which still needs the old
    // storage permission; the request is async, so the save waits for it.
    private fun saveWithPermission(result: MethodChannel.Result, action: () -> Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            action()
            return
        }
        pendingStorageSave = action
        pendingStorageResult = result
        requestPermissions(
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            STORAGE_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != STORAGE_REQUEST) return
        val action = pendingStorageSave
        val result = pendingStorageResult
        pendingStorageSave = null
        pendingStorageResult = null
        if (grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            action?.invoke()
        } else {
            result?.error(
                "permissionDenied",
                "Storage permission is required to save on Android 9 and below.",
                null,
            )
        }
    }

    private fun saveImage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val mime = call.argument<String>("mime") ?: "image/png"
        if (bytes == null || bytes.isEmpty()) {
            result.error("invalidImage", "The image payload is empty.", null)
            return
        }
        if (mime !in SUPPORTED_TYPES) {
            result.error("invalidImage", "Unsupported image type: $mime", null)
            return
        }
        val name = fileName(call.argument<String>("name"), mime)
        // MediaStore does disk and IPC work; keep it off the platform thread so
        // the UI does not stutter while a large image is written.
        val save = {
            Thread {
                try {
                    val uri = insert(bytes, name, mime)
                    runOnUiThread { result.success(uri.toString()) }
                } catch (error: Exception) {
                    runOnUiThread {
                        result.error("saveFailed", error.message ?: "Could not save the image.", null)
                    }
                }
            }.start()
        }
        saveWithPermission(result, save)
    }

    private fun insert(bytes: ByteArray, name: String, mime: String): Uri {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return insertScoped(bytes, name, mime)
        }
        return insertLegacy(bytes, name, mime, Environment.DIRECTORY_PICTURES, scan = true)
    }

    private fun insertScoped(bytes: ByteArray, name: String, mime: String): Uri {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val pending = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, mime)
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/$ALBUM")
            // IS_PENDING hides the row until the bytes are complete, so a failed
            // write never leaves a half image in the user's gallery.
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, pending)
            ?: throw IllegalStateException("The media library refused a new entry.")
        try {
            resolver.openOutputStream(uri).use { stream ->
                if (stream == null) throw IllegalStateException("The media library returned no stream.")
                stream.write(bytes)
            }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
        val published = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
        resolver.update(uri, published, null, null)
        return uri
    }

    private fun saveFile(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val mime = call.argument<String>("mime") ?: "application/octet-stream"
        if (bytes == null || bytes.isEmpty()) {
            result.error("invalidFile", "The file payload is empty.", null)
            return
        }
        val name = safeFileName(call.argument<String>("name"))
        val save = {
            Thread {
                try {
                    val uri = insertDownload(bytes, name, mime)
                    runOnUiThread { result.success(uri.toString()) }
                } catch (error: Exception) {
                    runOnUiThread {
                        result.error("saveFailed", error.message ?: "Could not save the file.", null)
                    }
                }
            }.start()
        }
        saveWithPermission(result, save)
    }

    private fun insertDownload(bytes: ByteArray, name: String, mime: String): Uri {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return insertDownloadScoped(bytes, name, mime)
        }
        return insertLegacy(bytes, name, mime, Environment.DIRECTORY_DOWNLOADS, scan = false)
    }

    private fun insertDownloadScoped(bytes: ByteArray, name: String, mime: String): Uri {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val pending = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$ALBUM")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, pending)
            ?: throw IllegalStateException("The download library refused a new entry.")
        try {
            resolver.openOutputStream(uri).use { stream ->
                if (stream == null) throw IllegalStateException("The download library returned no stream.")
                stream.write(bytes)
            }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
        val published = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
        resolver.update(uri, published, null, null)
        return uri
    }

    // API 24–28 has no scoped MediaStore entry point: write the bytes ourselves,
    // then let the scanner publish an image into the gallery.
    @Suppress("DEPRECATION")
    private fun insertLegacy(
        bytes: ByteArray,
        name: String,
        mime: String,
        directory: String,
        scan: Boolean,
    ): Uri {
        val folder = File(Environment.getExternalStoragePublicDirectory(directory), ALBUM)
        if (!folder.exists() && !folder.mkdirs()) {
            throw IllegalStateException("Could not create ${folder.absolutePath}.")
        }
        val file = uniqueFile(folder, name)
        FileOutputStream(file).use { it.write(bytes) }
        if (scan) {
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(file.absolutePath),
                arrayOf(mime),
                null,
            )
        }
        return Uri.fromFile(file)
    }

    private fun uniqueFile(folder: File, name: String): File {
        var candidate = File(folder, name)
        if (!candidate.exists()) return candidate
        val stem = name.substringBeforeLast('.', name)
        val extension = name.substringAfterLast('.', "")
        var index = 1
        while (candidate.exists()) {
            val next = if (extension.isEmpty()) "$stem ($index)" else "$stem ($index).$extension"
            candidate = File(folder, next)
            index++
        }
        return candidate
    }

    private fun safeFileName(requested: String?): String {
        val base = (requested ?: "")
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .substringBeforeLast('.')
            .filter { it.code >= 0x20 && it.code != 0x7F && it !in "\\/:*?\"<>|" }
            .trim()
            .take(70)
            .trim()
        return if (base.isEmpty()) "Imagyn-${System.currentTimeMillis()}.pptx" else "$base.pptx"
    }

    private fun fileName(requested: String?, mime: String): String {
        val extension = when (mime) {
            "image/jpeg" -> ".jpg"
            "image/webp" -> ".webp"
            else -> ".png"
        }
        val cleaned = (requested ?: "")
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .removeSuffix(extension)
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .trimStart('.', '_')
            .take(80)
        return if (cleaned.isEmpty()) "Imagyn-${System.currentTimeMillis()}$extension" else "$cleaned$extension"
    }
}
