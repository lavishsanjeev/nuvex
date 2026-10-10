import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/nuvex_database.dart';
import '../../../core/database/remote_file.dart';
import '../../../core/database/upload_queue_item.dart';
import '../../../core/services/native_media_service.dart';
import '../../../core/utils/file_hash.dart';
import '../../../telegram/telegram_media_service.dart';
import '../../../telegram/telegram_models.dart';

/// Repository managing the persistent upload queue and original-file duplicate detection.
///
/// Complies strictly with Nuvex requirements:
/// - Reuses existing TelegramMediaService original-quality document upload method
/// - Never creates a second Telegram client or authentication system
/// - Enforces SHA-256 duplicate detection before network upload starts
/// - SQLite persistence surviving app restarts
class UploadRepository {
  final NuvexDatabase _database;
  final TelegramMediaService _mediaService;

  UploadRepository({
    NuvexDatabase? database,
    TelegramMediaService? mediaService,
  }) : _database = database ?? NuvexDatabase(),
       _mediaService = mediaService ?? TelegramMediaService();

  NuvexDatabase get database => _database;
  TelegramMediaService get mediaService => _mediaService;

  /// Enqueues a local file into the persistent SQLite queue.
  Future<UploadQueueItem> enqueueFile(File file, {String? mimeType}) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    if (!await file.exists()) {
      throw FileSystemException('Cannot enqueue non-existent file', file.path);
    }

    final size = await file.length();
    final name = p.basename(file.path);
    final resolvedMime =
        mimeType ??
        NativeMediaService.resolveMimeType(fileName: name, currentMime: '');

    final now = DateTime.now();
    final item = UploadQueueItem(
      filePath: file.path,
      fileName: name,
      fileSize: size,
      mimeType: resolvedMime,
      status: UploadStatus.pending,
      progress: 0.0,
      createdAt: now,
      updatedAt: now,
    );

    final id = await _database.insertUploadQueueItem(item);
    return item.copyWith(id: id);
  }

  /// Retrieves all items currently stored in the persistent upload queue.
  Future<List<UploadQueueItem>> getQueueItems() async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _database.getUploadQueue();
  }

  /// Calculates SHA-256 hash strictly from the original file bytes.
  Future<String> calculateSha256(File file) => calculateFileSha256(file);

  /// Checks if an identical SHA-256 hash already exists in remote_files or completed queue.
  Future<bool> hasDuplicateHash(String hash) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _database.hasFileWithSha256(hash);
  }

  /// Uploads a single queue item to Telegram using the existing document upload method.
  Future<RemoteFile> uploadQueueItem({
    required UploadQueueItem item,
    void Function(double progress)? onProgress,
    TelegramUploadCancelToken? cancelToken,
  }) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }

    final file = File(item.filePath);
    final result = await _mediaService.uploadDocumentFile(
      file: file,
      mimeType: item.mimeType,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );

    final remoteFile = result.toRemoteFile(
      localPath: file.path,
      sha256: item.sha256,
    );
    await _database.upsertFiles([remoteFile]);
    debugPrint(
      '[UPLOAD_REPO] Successfully uploaded & persisted #${remoteFile.telegramMessageId} (${remoteFile.name})',
    );
    return remoteFile;
  }

  /// Resets any items left in 'uploading' state back to 'pending' upon startup.
  Future<void> recoverInterruptedUploads() async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    await _database.resetUploadingToPending();
  }
}
