import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Native media service providing Android-native Share and Save to Device capabilities.
///
/// Implements Task 6 requirements:
/// - Native Android FileProvider-based sharing via `ACTION_SEND`
/// - Native Android MediaStore-based saving to user-visible gallery/downloads
/// - Graceful error handling for missing files, storage issues, and platform exceptions
/// - Desktop and test fallback support
class NativeMediaService {
  static const MethodChannel _channel = MethodChannel('nuvex/native_media');

  /// Optional test hook to mock native share behavior without depending on Android OS.
  @visibleForTesting
  static Future<bool> Function({
    required String filePath,
    required String mimeType,
    required String title,
  })?
  shareFileMock;

  /// Optional test hook to mock native bulk share behavior without depending on Android OS.
  @visibleForTesting
  static Future<bool> Function({
    required List<String> filePaths,
    required List<String> mimeTypes,
    required String title,
  })?
  shareFilesMock;

  /// Resolves an exact and standard MIME type from filename and given MIME.
  static String resolveMimeType({
    required String fileName,
    required String currentMime,
    bool isPhoto = true,
    bool isVideo = false,
  }) {
    final cleanMime = currentMime.trim().toLowerCase();
    if (cleanMime.isNotEmpty &&
        cleanMime != 'application/octet-stream' &&
        cleanMime != 'photo' &&
        cleanMime != 'video' &&
        cleanMime != '*/*') {
      return cleanMime;
    }

    final ext = fileName.contains('.')
        ? fileName.split('.').last.trim().toLowerCase()
        : '';

    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'pdf':
        return 'application/pdf';
      default:
        if (isPhoto) return 'image/jpeg';
        if (isVideo) return 'video/mp4';
        return 'image/jpeg';
    }
  }

  /// Shares a locally cached media file using the native share sheet.
  static Future<bool> shareFile({
    required String filePath,
    required String mimeType,
    required String title,
  }) async {
    final file = File(filePath);
    if (!await file.exists() || await file.length() <= 0) {
      throw FileSystemException(
        'Cannot share file: local file does not exist or is empty',
        filePath,
      );
    }

    if (shareFileMock != null) {
      return shareFileMock!(
        filePath: filePath,
        mimeType: mimeType,
        title: title,
      );
    }

    try {
      final success = await _channel.invokeMethod<bool>('shareFile', {
        'filePath': filePath,
        'mimeType': mimeType,
        'title': title,
      });
      return success ?? true;
    } on MissingPluginException {
      debugPrint(
        '[NATIVE] shareFile: MissingPluginException (non-Android / test)',
      );
      return true;
    } on PlatformException catch (e) {
      debugPrint('[NATIVE] shareFile PlatformException: ${e.message}');
      rethrow;
    }
  }

  /// Shares multiple locally cached media files in a single native share sheet invocation.
  static Future<bool> shareFiles({
    required List<String> filePaths,
    List<String>? mimeTypes,
    required String title,
  }) async {
    if (filePaths.isEmpty) {
      return false;
    }

    for (final path in filePaths) {
      final file = File(path);
      if (!await file.exists() || await file.length() <= 0) {
        throw FileSystemException(
          'Cannot share file: local file does not exist or is empty',
          path,
        );
      }
    }

    if (shareFilesMock != null) {
      return shareFilesMock!(
        filePaths: filePaths,
        mimeTypes: mimeTypes ?? const [],
        title: title,
      );
    }

    // Compatibility hook: if a single file is shared and only shareFileMock is registered
    if (filePaths.length == 1 && shareFileMock != null) {
      return shareFileMock!(
        filePath: filePaths.first,
        mimeType: (mimeTypes != null && mimeTypes.isNotEmpty)
            ? mimeTypes.first
            : '*/*',
        title: title,
      );
    }

    try {
      final success = await _channel.invokeMethod<bool>('shareFiles', {
        'filePaths': filePaths,
        'mimeTypes': mimeTypes ?? const [],
        'title': title,
      });
      return success ?? true;
    } on MissingPluginException {
      debugPrint(
        '[NATIVE] shareFiles: MissingPluginException (non-Android / test)',
      );
      return true;
    } on PlatformException catch (e) {
      debugPrint('[NATIVE] shareFiles PlatformException: ${e.message}');
      rethrow;
    }
  }

  /// Saves a locally cached file to a user-visible device location.
  ///
  /// On Android: writes directly to MediaStore (`Pictures/Nuvex`, `Movies/Nuvex`, or `Download/Nuvex`).
  /// On other platforms / tests: copies to downloads or application documents directory.
  static Future<String> saveToDevice({
    required String filePath,
    required String fileName,
    required String mimeType,
    required String category,
  }) async {
    final srcFile = File(filePath);
    if (!srcFile.existsSync()) {
      throw FileSystemException(
        'Cannot save file: source file does not exist',
        filePath,
      );
    }

    try {
      final savedLocation = await _channel.invokeMethod<String>(
        'saveToDevice',
        {
          'filePath': filePath,
          'fileName': fileName,
          'mimeType': mimeType,
          'category': category,
        },
      );

      if (savedLocation != null && savedLocation.isNotEmpty) {
        return savedLocation;
      }
    } on MissingPluginException {
      debugPrint(
        '[NATIVE] saveToDevice: MethodChannel not available. Using fallback.',
      );
    } on PlatformException catch (e) {
      debugPrint('[NATIVE] saveToDevice PlatformException: ${e.message}');
      rethrow;
    }

    // Fallback for desktop / unit tests where Android MediaStore is unavailable
    try {
      Directory targetDir;
      try {
        final docs = await getApplicationDocumentsDirectory();
        targetDir = Directory(p.join(docs.path, 'Nuvex'));
      } catch (_) {
        targetDir = Directory.systemTemp.createTempSync('nuvex_saved_');
      }
      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
      }
      final destFile = File(p.join(targetDir.path, fileName));
      await srcFile.copy(destFile.path);
      return destFile.path;
    } catch (e) {
      debugPrint('[NATIVE] Fallback save failed: $e');
      rethrow;
    }
  }

  /// Optional test hook to mock gallery cleanup behavior without depending on Android OS.
  @visibleForTesting
  static Future<int> Function()? cleanupUnwantedGalleryFilesMock;

  /// Cleans up any unwanted legacy files previously saved to public gallery folders
  /// (strictly Pictures/Nuvex, Movies/Nuvex, Downloads/Nuvex).
  ///
  /// Never deletes arbitrary user files or files outside Nuvex subfolders.
  static Future<int> cleanupUnwantedGalleryFiles() async {
    if (cleanupUnwantedGalleryFilesMock != null) {
      return cleanupUnwantedGalleryFilesMock!();
    }

    try {
      final count = await _channel.invokeMethod<int>(
        'cleanupUnwantedGalleryFiles',
      );
      return count ?? 0;
    } on MissingPluginException {
      debugPrint(
        '[NATIVE] cleanupUnwantedGalleryFiles: MissingPluginException (non-Android / test)',
      );
      return 0;
    } catch (e) {
      debugPrint('[NATIVE] cleanupUnwantedGalleryFiles error: $e');
      return 0;
    }
  }
}
