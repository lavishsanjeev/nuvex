// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/database/nuvex_database.dart';
import '../../../core/database/remote_file.dart';
import '../../../core/utils/image_dimensions.dart';
import '../../home/repositories/media_repository.dart';
import '../services/locked_media_cryptor.dart';

/// Repository managing encrypted storage, metadata updates, and safe atomic moves
/// for the Nuvex Locked Folder.
///
/// Security & Data Safety Guarantees:
/// - Isolated `.nomedia` directory `locked_media/` inside app documents.
/// - Encrypts media before committing database changes.
/// - Verifies decryption integrity before deleting plaintext originals.
/// - Removes public thumbnails from `nuvex_thumbs/` to prevent leaks.
/// - Does NOT delete Telegram cloud messages when moving into Locked Folder.
class LockedFolderRepository {
  final NuvexDatabase _database;
  final MediaRepository _mediaRepository;
  Directory? _lockedDir;
  Directory? _lockedThumbsDir;

  LockedFolderRepository({
    NuvexDatabase? database,
    required MediaRepository mediaRepository,
  })  : _database = database ?? NuvexDatabase(),
        _mediaRepository = mediaRepository;

  /// Returns the base directory for encrypted media.
  Future<Directory> getLockedDirectory() async {
    if (_lockedDir != null && await _lockedDir!.exists()) {
      return _lockedDir!;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'locked_media'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // Prevent Android media scanner from indexing the folder
    final noMedia = File(p.join(dir.path, '.nomedia'));
    if (!await noMedia.exists()) {
      try {
        await noMedia.create();
      } catch (_) {}
    }
    _lockedDir = dir;
    return dir;
  }

  /// Returns the directory for encrypted private thumbnails.
  Future<Directory> getLockedThumbsDirectory() async {
    if (_lockedThumbsDir != null && await _lockedThumbsDir!.exists()) {
      return _lockedThumbsDir!;
    }
    final lockedDir = await getLockedDirectory();
    final thumbsDir = Directory(p.join(lockedDir.path, 'thumbs'));
    if (!await thumbsDir.exists()) {
      await thumbsDir.create(recursive: true);
    }
    final noMedia = File(p.join(thumbsDir.path, '.nomedia'));
    if (!await noMedia.exists()) {
      try {
        await noMedia.create();
      } catch (_) {}
    }
    _lockedThumbsDir = thumbsDir;
    return thumbsDir;
  }

  /// Retrieves all locked media files.
  Future<List<RemoteFile>> getLockedFiles({int limit = 100, int offset = 0}) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _database.getFilesByCategory('locked', limit: limit, offset: offset);
  }

  /// Moves a photo or video into the secure Locked Folder.
  ///
  /// Steps:
  /// 1. Ensures original bytes exist locally (downloads on demand from Telegram if missing).
  /// 2. Encrypts original bytes into `locked_media/<id>.enc`.
  /// 3. If thumbnail exists, encrypts thumbnail to `locked_media/thumbs/<id>.enc`
  ///    and deletes the public thumbnail from `nuvex_thumbs/`.
  /// 4. Updates SQLite record: `isLocked = 1`, `localPath = encryptedPath`, `thumbnailPath = encryptedThumbPath`.
  /// 5. Safely deletes plaintext original from `nuvex_media/`.
  Future<RemoteFile> moveToLockedFolder({
    required RemoteFile file,
    required Uint8List masterKey,
  }) async {
    final lockedDir = await getLockedDirectory();
    final lockedThumbsDir = await getLockedThumbsDirectory();

    // 1. Ensure file bytes are locally available
    String sourcePath;

    if (file.localPath != null &&
        await File(file.localPath!).exists() &&
        await File(file.localPath!).length() > 0) {
      sourcePath = file.localPath!;
    } else {
      // Fetch original bytes on demand from Telegram
      debugPrint('[LOCKED_REPO] Fetching original bytes from Telegram for #${file.telegramMessageId}');
      final downloaded = await _mediaRepository.ensureFileDownloaded(file);
      if (downloaded.localPath == null || !await File(downloaded.localPath!).exists()) {
        throw StateError('Failed to fetch media bytes from Telegram before locking');
      }
      sourcePath = downloaded.localPath!;
    }

    final targetEncPath = p.join(
      lockedDir.path,
      '${file.telegramMessageId}.enc',
    );
    final targetEncFile = File(targetEncPath);

    // 2. Encrypt original bytes with AES-256-GCM and verify integrity
    await LockedMediaCryptor.encryptFile(
      sourceFile: File(sourcePath),
      destinationFile: targetEncFile,
      masterKey: masterKey,
    );

    // 3. Encrypt thumbnail if available, then prune unencrypted thumbnail from public cache
    String? targetEncThumbPath;
    if (file.thumbnailPath != null && await File(file.thumbnailPath!).exists()) {
      targetEncThumbPath = p.join(
        lockedThumbsDir.path,
        '${file.telegramMessageId}_thumb.enc',
      );
      try {
        await LockedMediaCryptor.encryptFile(
          sourceFile: File(file.thumbnailPath!),
          destinationFile: File(targetEncThumbPath),
          masterKey: masterKey,
        );
        // Prune public unencrypted thumbnail from gallery cache
        await File(file.thumbnailPath!).delete();
      } catch (e) {
        debugPrint('[LOCKED_REPO] Warning: failed to encrypt thumbnail: $e');
        targetEncThumbPath = null;
      }
    }

    // 4. Update SQLite database to isolate file from normal gallery
    final updatedFile = file.copyWith(
      isLocked: true,
      localPath: targetEncPath,
      thumbnailPath: targetEncThumbPath,
    );

    await _database.updateFileLockState(
      file.telegramMessageId,
      isLocked: true,
      localPath: targetEncPath,
      thumbnailPath: targetEncThumbPath,
    );

    // 5. Delete original plaintext file now that encrypted file is verified
    try {
      final srcFile = File(sourcePath);
      if (await srcFile.exists()) {
        await srcFile.delete();
      }
    } catch (e) {
      debugPrint('[LOCKED_REPO] Warning: error deleting plaintext original: $e');
    }

    return updatedFile;
  }

  /// Restores a protected file back to the standard gallery.
  ///
  /// Steps:
  /// 1. Decrypts `locked_media/<id>.enc` back to `nuvex_media/<id>_<name>`.
  /// 2. Decrypts thumbnail back to `nuvex_thumbs/`.
  /// 3. Updates SQLite record: `isLocked = 0`, `localPath = restoredMedia`.
  /// 4. Deletes encrypted `.enc` files from `locked_media/`.
  Future<RemoteFile> restoreFromLockedFolder({
    required RemoteFile file,
    required Uint8List masterKey,
  }) async {
    if (file.localPath == null || !await File(file.localPath!).exists()) {
      throw StateError('Encrypted file does not exist on disk: ${file.localPath}');
    }

    final mediaDir = await _mediaRepository.getMediaDirectory();
    final thumbsDir = await _mediaRepository.getThumbsDirectory();

    final restoredMediaPath = p.join(
      mediaDir,
      '${file.telegramMessageId}_${file.name}',
    );
    final restoredMediaFile = File(restoredMediaPath);

    // 1. Decrypt media
    await LockedMediaCryptor.decryptFile(
      encryptedFile: File(file.localPath!),
      destinationFile: restoredMediaFile,
      masterKey: masterKey,
    );

    // Verify restored original media is accessible and valid
    if (!await restoredMediaFile.exists() || await restoredMediaFile.length() == 0) {
      throw StateError('Restored media file verification failed for #${file.telegramMessageId}');
    }

    // 2. Decrypt thumbnail if present
    String? restoredThumbPath;
    if (file.thumbnailPath != null && await File(file.thumbnailPath!).exists()) {
      restoredThumbPath = p.join(
        thumbsDir,
        '${file.telegramMessageId}_hq.jpg',
      );
      try {
        await LockedMediaCryptor.decryptFile(
          encryptedFile: File(file.thumbnailPath!),
          destinationFile: File(restoredThumbPath),
          masterKey: masterKey,
        );
        if (await File(restoredThumbPath).exists() && await File(restoredThumbPath).length() > 0) {
          markThumbnailAsValidated(restoredThumbPath);
        } else {
          restoredThumbPath = null;
        }
      } catch (e) {
        debugPrint('[LOCKED_REPO] Warning: could not restore thumbnail: $e');
        restoredThumbPath = null;
      }
    }

    // Fallback: If thumbnail was missing or failed, but restored media file is a photo
    if ((restoredThumbPath == null || !await File(restoredThumbPath).exists()) && !file.isVideo) {
      if (await restoredMediaFile.exists() && await restoredMediaFile.length() > 0) {
        final fallbackThumbPath = p.join(thumbsDir, '${file.telegramMessageId}_hq.jpg');
        try {
          await restoredMediaFile.copy(fallbackThumbPath);
          restoredThumbPath = fallbackThumbPath;
          markThumbnailAsValidated(restoredThumbPath);
        } catch (_) {
          restoredThumbPath = restoredMediaPath;
        }
      }
    }

    // 3. Update SQLite database with unlocked state
    final updatedFile = file.copyWith(
      isLocked: false,
      localPath: restoredMediaPath,
      thumbnailPath: restoredThumbPath,
    );

    await _database.updateFileLockState(
      file.telegramMessageId,
      isLocked: false,
      localPath: restoredMediaPath,
      thumbnailPath: restoredThumbPath,
    );

    // 4. Safely delete encrypted files ONLY after verified restore and DB update
    try {
      final encFile = File(file.localPath!);
      if (await encFile.exists()) {
        await encFile.delete();
      }
      if (file.thumbnailPath != null) {
        final encThumb = File(file.thumbnailPath!);
        if (await encThumb.exists()) {
          await encThumb.delete();
        }
      }
    } catch (e) {
      debugPrint('[LOCKED_REPO] Warning: could not delete encrypted files: $e');
    }

    return updatedFile;
  }

  /// Permanently deletes an encrypted file from disk and database.
  Future<void> deleteLockedFile(RemoteFile file) async {
    if (file.localPath != null && await File(file.localPath!).exists()) {
      try {
        await File(file.localPath!).delete();
      } catch (_) {}
    }
    if (file.thumbnailPath != null && await File(file.thumbnailPath!).exists()) {
      try {
        await File(file.thumbnailPath!).delete();
      } catch (_) {}
    }
    await _database.deleteFile(file.telegramMessageId);
  }

  /// Decrypts thumbnail bytes directly into memory for safe in-app display.
  Future<Uint8List?> getDecryptedThumbnailBytes({
    required RemoteFile file,
    required Uint8List masterKey,
  }) async {
    // 1. If encrypted thumbnail exists, decrypt it
    if (file.thumbnailPath != null && await File(file.thumbnailPath!).exists()) {
      try {
        final encBytes = await File(file.thumbnailPath!).readAsBytes();
        return LockedMediaCryptor.decryptBytes(
          encryptedBytes: encBytes,
          masterKey: masterKey,
        );
      } catch (e) {
        debugPrint('[LOCKED_REPO] Error decrypting thumbnail bytes: $e');
      }
    }

    // 2. Fallback: if it's a photo and encrypted media exists, decrypt photo bytes
    if (file.isPhoto && file.localPath != null && await File(file.localPath!).exists()) {
      try {
        final encBytes = await File(file.localPath!).readAsBytes();
        return LockedMediaCryptor.decryptBytes(
          encryptedBytes: encBytes,
          masterKey: masterKey,
        );
      } catch (e) {
        debugPrint('[LOCKED_REPO] Error decrypting photo bytes: $e');
      }
    }

    return null;
  }

  /// Decrypts full media bytes directly into memory (e.g. for photo viewing without writing plaintext).
  Future<Uint8List> getDecryptedMediaBytes({
    required RemoteFile file,
    required Uint8List masterKey,
  }) async {
    if (file.localPath == null || !await File(file.localPath!).exists()) {
      throw StateError('Encrypted file not found on disk');
    }
    final encBytes = await File(file.localPath!).readAsBytes();
    return LockedMediaCryptor.decryptBytes(
      encryptedBytes: encBytes,
      masterKey: masterKey,
    );
  }

  /// Safely decrypts a locked video into an app-private cache directory for playback.
  /// The caller must delete this file when the player/viewer is closed.
  Future<File?> getDecryptedTempVideoFile({
    required RemoteFile file,
    required Uint8List masterKey,
  }) async {
    if (file.localPath == null || !await File(file.localPath!).exists()) {
      return null;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final tempDir = Directory(p.join(appDir.path, 'locked_temp'));
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    final noMedia = File(p.join(tempDir.path, '.nomedia'));
    if (!await noMedia.exists()) {
      try {
        await noMedia.create();
      } catch (_) {}
    }

    final ext = p.extension(file.name).isNotEmpty ? p.extension(file.name) : '.mp4';
    final destinationFile = File(p.join(tempDir.path, 'temp_${file.telegramMessageId}$ext'));

    await LockedMediaCryptor.decryptFile(
      encryptedFile: File(file.localPath!),
      destinationFile: destinationFile,
      masterKey: masterKey,
    );
    return destinationFile;
  }
}
