package app.imagyn

import android.content.ContentValues
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Implements the `app.imagyn/media` channel declared in the Dart layer.
 *
 * `saveImage` writes one finished image into the shared `Pictures/Imagyn`
 * folder through MediaStore, so the file shows up in the system gallery. That
 * needs neither a storage permission nor root on API 29 and above, and it never
 * touches the private copy the app keeps for its own history.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "app.imagyn/media"
        const val ALBUM = "Imagyn"
        val SUPPORTED_TYPES = setOf("image/png", "image/jpeg", "image/webp")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> saveImage(call, result)
                    else -> result.notImplemented()
                }
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

    private fun insert(bytes: ByteArray, name: String, mime: String): Uri {
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
