package com.example.nuvex

import android.content.ClipData
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "nuvex/native_media"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "shareFile" -> {
                    val filePath = call.argument<String>("filePath")
                    val mimeType = call.argument<String>("mimeType") ?: "image/jpeg"
                    val title = call.argument<String>("title") ?: "Share Media"

                    if (filePath == null) {
                        result.error("INVALID_ARGS", "filePath must not be null", null)
                        return@setMethodCallHandler
                    }

                    val file = File(filePath)
                    if (!file.exists() || file.length() == 0L) {
                        result.error("FILE_NOT_FOUND", "Local file does not exist or is empty: $filePath", null)
                        return@setMethodCallHandler
                    }

                    try {
                        // Ensure shared_media cache directory exists, has .nomedia, and prune stale items
                        val sharedDir = File(cacheDir, "shared_media").apply {
                            if (!exists()) mkdirs()
                            try { File(this, ".nomedia").createNewFile() } catch (_: Exception) {}
                        }
                        cleanSharedMediaCache(sharedDir)

                        // Strip internal database message ID prefix if present for clean receiver display
                        val cleanFileName = file.name.replace(Regex("^\\d+_"), "")
                        val targetFile = File(sharedDir, if (cleanFileName.isNotBlank()) cleanFileName else file.name)

                        // Copy original to cache if not already present with exact size
                        if (!targetFile.exists() || targetFile.length() != file.length()) {
                            file.copyTo(targetFile, overwrite = true)
                        }

                        val contentUri: Uri = FileProvider.getUriForFile(
                            this,
                            "${packageName}.fileprovider",
                            targetFile
                        )

                        val resolvedMime = if (mimeType.isNotBlank() && mimeType != "*/*") mimeType else "image/jpeg"

                        val shareIntent = Intent(Intent.ACTION_SEND).apply {
                            type = resolvedMime
                            putExtra(Intent.EXTRA_STREAM, contentUri)
                            clipData = ClipData.newRawUri("Nuvex Photo", contentUri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }

                        val chooser = Intent.createChooser(shareIntent, title).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }

                        // Explicitly grant read URI permissions to resolved activities
                        val resInfoList = packageManager.queryIntentActivities(shareIntent, PackageManager.MATCH_DEFAULT_ONLY)
                        for (resolveInfo in resInfoList) {
                            val pkgName = resolveInfo.activityInfo.packageName
                            grantUriPermission(pkgName, contentUri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }

                        startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.localizedMessage, null)
                    }
                }

                "shareFiles" -> {
                    val filePaths = call.argument<List<String>>("filePaths")
                    val mimeTypes = call.argument<List<String>>("mimeTypes") ?: emptyList()
                    val title = call.argument<String>("title") ?: "Share Media"

                    if (filePaths.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "filePaths must not be null or empty", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val sharedDir = File(cacheDir, "shared_media").apply {
                            if (!exists()) mkdirs()
                            try { File(this, ".nomedia").createNewFile() } catch (_: Exception) {}
                        }
                        cleanSharedMediaCache(sharedDir)

                        val uris = ArrayList<Uri>()
                        for (filePath in filePaths) {
                            val file = File(filePath)
                            if (file.exists() && file.length() > 0L) {
                                val cleanFileName = file.name.replace(Regex("^\\d+_"), "")
                                val targetFile = File(sharedDir, if (cleanFileName.isNotBlank()) cleanFileName else file.name)
                                if (!targetFile.exists() || targetFile.length() != file.length()) {
                                    file.copyTo(targetFile, overwrite = true)
                                }
                                val contentUri: Uri = FileProvider.getUriForFile(
                                    this,
                                    "${packageName}.fileprovider",
                                    targetFile
                                )
                                uris.add(contentUri)
                            }
                        }

                        if (uris.isEmpty()) {
                            result.error("FILE_NOT_FOUND", "No valid local files found to share", null)
                            return@setMethodCallHandler
                        }

                        var resolvedMime = "*/*"
                        if (mimeTypes.isNotEmpty()) {
                            val first = mimeTypes[0].trim()
                            val allSame = mimeTypes.all { it.trim() == first }
                            if (allSame && first.isNotBlank() && first != "*/*") {
                                resolvedMime = first
                            } else {
                                val prefix = first.substringBefore('/')
                                val allSameType = mimeTypes.all { it.trim().startsWith("$prefix/") }
                                if (allSameType && prefix.isNotBlank()) {
                                    resolvedMime = "$prefix/*"
                                }
                            }
                        }

                        val shareIntent = if (uris.size == 1) {
                            Intent(Intent.ACTION_SEND).apply {
                                type = resolvedMime
                                putExtra(Intent.EXTRA_STREAM, uris[0])
                                clipData = ClipData.newRawUri("Nuvex Media", uris[0])
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                        } else {
                            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                                type = resolvedMime
                                putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                                val clip = ClipData.newRawUri("Nuvex Media", uris[0])
                                for (i in 1 until uris.size) {
                                    clip.addItem(ClipData.Item(uris[i]))
                                }
                                clipData = clip
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                        }

                        val chooser = Intent.createChooser(shareIntent, title).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }

                        val resInfoList = packageManager.queryIntentActivities(shareIntent, PackageManager.MATCH_DEFAULT_ONLY)
                        for (resolveInfo in resInfoList) {
                            val pkgName = resolveInfo.activityInfo.packageName
                            for (uri in uris) {
                                grantUriPermission(pkgName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                        }

                        startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.localizedMessage, null)
                    }
                }

                "saveToDevice" -> {
                    val filePath = call.argument<String>("filePath")
                    val fileName = call.argument<String>("fileName") ?: "downloaded_file"
                    val mimeType = call.argument<String>("mimeType") ?: "*/*"
                    val category = call.argument<String>("category") ?: "documents"

                    if (filePath == null) {
                        result.error("INVALID_ARGS", "filePath must not be null", null)
                        return@setMethodCallHandler
                    }

                    val srcFile = File(filePath)
                    if (!srcFile.exists()) {
                        result.error("FILE_NOT_FOUND", "Source file does not exist: $filePath", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val savedPath = saveMediaToDevice(srcFile, fileName, mimeType, category)
                        result.success(savedPath)
                    } catch (e: Exception) {
                        result.error("SAVE_FAILED", e.localizedMessage, null)
                    }
                }

                "cleanupUnwantedGalleryFiles" -> {
                    try {
                        val count = cleanupUnwantedGalleryMedia()
                        result.success(count)
                    } catch (e: Exception) {
                        result.error("CLEANUP_FAILED", e.localizedMessage, null)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun saveMediaToDevice(
        srcFile: File,
        fileName: String,
        mimeType: String,
        category: String
    ): String {
        val isImage = category == "photos" || mimeType.startsWith("image/")
        val isVideo = category == "videos" || mimeType.startsWith("video/")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.IS_PENDING, 1)

                val relativePath = when {
                    isImage -> "${Environment.DIRECTORY_PICTURES}/Nuvex"
                    isVideo -> "${Environment.DIRECTORY_MOVIES}/Nuvex"
                    else -> "${Environment.DIRECTORY_DOWNLOADS}/Nuvex"
                }
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            }

            val collectionUri = when {
                isImage -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                isVideo -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
            }

            val itemUri = resolver.insert(collectionUri, contentValues)
                ?: throw IllegalStateException("Failed to create MediaStore entry")

            resolver.openOutputStream(itemUri)?.use { out ->
                FileInputStream(srcFile).use { `in` ->
                    `in`.copyTo(out)
                }
            } ?: throw IllegalStateException("Failed to open output stream for $itemUri")

            contentValues.clear()
            contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(itemUri, contentValues, null, null)

            val displayFolder = when {
                isImage -> "Pictures/Nuvex"
                isVideo -> "Movies/Nuvex"
                else -> "Downloads/Nuvex"
            }
            return "$displayFolder/$fileName"
        } else {
            // Legacy Android (API < 29)
            val baseDir = when {
                isImage -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                isVideo -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
                else -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            }
            val targetDir = File(baseDir, "Nuvex")
            if (!targetDir.exists()) {
                targetDir.mkdirs()
            }
            val targetFile = File(targetDir, fileName)

            FileInputStream(srcFile).use { `in` ->
                FileOutputStream(targetFile).use { out ->
                    `in`.copyTo(out)
                }
            }

            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(targetFile.absolutePath),
                arrayOf(mimeType),
                null
            )

            return targetFile.absolutePath
        }
    }

    private fun cleanSharedMediaCache(sharedDir: File) {
        try {
            val files = sharedDir.listFiles() ?: return
            val oneDayAgo = System.currentTimeMillis() - 24 * 60 * 60 * 1000
            val sortedFiles = files.filter { it.name != ".nomedia" }.sortedByDescending { it.lastModified() }
            for (i in sortedFiles.indices) {
                val f = sortedFiles[i]
                if (i >= 100 || f.lastModified() < oneDayAgo) {
                    f.delete()
                }
            }
        } catch (_: Exception) {
            // Prune error ignored
        }
    }

    private fun cleanupUnwantedGalleryMedia(): Int {
        var deletedCount = 0

        // 1. Android 10+ (API >= 29) MediaStore cleanup strictly for Nuvex subfolders
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val targets = listOf(
                Pair(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "Pictures/Nuvex%"),
                Pair(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "Movies/Nuvex%"),
                Pair(MediaStore.Downloads.EXTERNAL_CONTENT_URI, "Downloads/Nuvex%")
            )

            for ((uri, pathPattern) in targets) {
                try {
                    val projection = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.RELATIVE_PATH)
                    val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
                    val selectionArgs = arrayOf(pathPattern)

                    val toDelete = mutableListOf<Uri>()
                    resolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
                        val idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                        while (cursor.moveToNext()) {
                            val id = cursor.getLong(idColumn)
                            toDelete.add(ContentUris.withAppendedId(uri, id))
                        }
                    }

                    for (itemUri in toDelete) {
                        try {
                            val rows = resolver.delete(itemUri, null, null)
                            if (rows > 0) deletedCount += rows
                        } catch (_: Exception) {}
                    }
                } catch (_: Exception) {}
            }
        }

        // 2. Legacy public directories: ONLY files inside Pictures/Nuvex/, Movies/Nuvex/, Downloads/Nuvex/
        val legacyDirs = listOf(
            File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Nuvex"),
            File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "Nuvex"),
            File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Nuvex")
        )

        for (dir in legacyDirs) {
            try {
                if (dir.exists() && dir.isDirectory && dir.name == "Nuvex") {
                    val files = dir.listFiles()
                    if (files != null) {
                        val deletedPaths = mutableListOf<String>()
                        for (f in files) {
                            if (f.isFile) {
                                val path = f.absolutePath
                                if (f.delete()) {
                                    deletedCount++
                                    deletedPaths.add(path)
                                }
                            }
                        }
                        if (deletedPaths.isNotEmpty()) {
                            MediaScannerConnection.scanFile(
                                applicationContext,
                                deletedPaths.toTypedArray(),
                                null,
                                null
                            )
                        }
                    }
                    if (dir.listFiles()?.isEmpty() == true) {
                        dir.delete()
                    }
                }
            } catch (_: Exception) {}
        }

        // 3. Ensure app-private shared_media cache has .nomedia
        try {
            val sharedDir = File(cacheDir, "shared_media")
            if (sharedDir.exists()) {
                val noMedia = File(sharedDir, ".nomedia")
                if (!noMedia.exists()) {
                    noMedia.createNewFile()
                }
            }
        } catch (_: Exception) {}

        return deletedCount
    }
}
