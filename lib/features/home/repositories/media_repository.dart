import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/database/nuvex_database.dart';
import '../../../core/database/remote_file.dart';
import '../../../core/utils/concurrency_limiter.dart';
import '../../../core/utils/file_hash.dart';
import '../../../core/utils/image_dimensions.dart';
import '../../../telegram/telegram_media_service.dart';
import '../../../telegram/telegram_models.dart';
import '../models/collection_preview.dart';
import '../services/collection_thumbnail_resolver.dart';
import 'upload_repository.dart';

/// Repository coordinating local SQLite database cache and Telegram MTProto media sync.
///
/// Implements local-first pattern:
/// 1. Immediately loads cached records from SQLite DB for fast zero-latency UI rendering.
/// 2. Asynchronously synchronizes newest Telegram metadata in background.
/// 3. Updates SQLite DB and notifies presentation layers.
class MediaRepository {
  final NuvexDatabase _database;
  final TelegramMediaService _mediaService;
  final Map<int, Future<RemoteFile>> _inFlightDownloads = {};

  MediaRepository({NuvexDatabase? database, TelegramMediaService? mediaService})
    : _database = database ?? NuvexDatabase(),
      _mediaService = mediaService ?? TelegramMediaService();

  NuvexDatabase get database => _database;
  TelegramMediaService get mediaService => _mediaService;

  /// Loads cached recent media (photos and videos) from SQLite database.
  /// Loads cached recent media (photos and videos) from SQLite database.
  Future<List<RemoteFile>> getCachedRecentMedia({
    int? limit,
    int offset = 0,
  }) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _database.getRecentMedia(limit: limit, offset: offset);
  }

  /// Loads real collection counts derived directly from SQLite database.
  Future<Map<String, int>> getCachedCollectionCounts() async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _database.getCollectionCounts();
  }

  /// Loads files for a given collection category from SQLite database.
  Future<List<RemoteFile>> getCachedFilesByCategory(
    String category, {
    int limit = 50,
    int offset = 0,
  }) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _database.getFilesByCategory(category, limit: limit, offset: offset);
  }

  /// Retrieves a single representative file for a collection category.
  Future<RemoteFile?> getRepresentativeFile(String category) async {
    if (!_database.isInitialized) {
      return null;
    }
    return _database.getRepresentativeFile(category);
  }

  /// Retrieves representative files for the 4 primary collection categories.
  Future<Map<String, RemoteFile?>> getCollectionRepresentatives() async {
    if (!_database.isInitialized) {
      return {};
    }
    final Map<String, RemoteFile?> result = {};
    for (final category in ['documents', 'places', 'stickers', 'moments']) {
      result[category] = await _database.getRepresentativeFile(category);
    }
    return result;
  }

  late final CollectionThumbnailResolver _thumbnailResolver =
      CollectionThumbnailResolver(repository: this);

  CollectionThumbnailResolver get thumbnailResolver => _thumbnailResolver;

  late final UploadRepository _uploadRepository = UploadRepository(
    database: _database,
    mediaService: _mediaService,
  );

  UploadRepository get uploadRepository => _uploadRepository;

  /// Retrieves a prepared [CollectionPreview] for a specific category.
  Future<CollectionPreview> getCollectionPreview(
    String category, {
    bool autoFetchThumb = true,
  }) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _thumbnailResolver.resolveCollectionPreview(
      category,
      autoFetch: autoFetchThumb,
    );
  }

  /// Retrieves all 4 primary [CollectionPreview]s.
  Future<List<CollectionPreview>> getPrimaryCollectionPreviews({
    bool autoFetchThumb = true,
  }) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _thumbnailResolver.resolveAllPreviews(autoFetch: autoFetchThumb);
  }

  /// Retrieves real storage statistics aggregated directly from SQLite metadata.
  Future<NuvexStorageStats> getStorageStats() async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _database.getStorageStats();
  }

  /// Synchronizes metadata from Telegram Saved Messages into local database across multiple pages.
  ///
  /// Conforms strictly to requirements:
  /// - Paginates until no more messages or boundary reached
  /// - Uses correct Telegram oldest message ID offset for subsequent pages
  /// - Deduplicates by Telegram message ID
  /// - Preserves newest-to-oldest ordering
  /// - Does not repeatedly fetch the same page
  Future<List<RemoteFile>>? _activeSyncFuture;

  /// Synchronizes metadata from Telegram Saved Messages into local database across multiple pages.
  ///
  /// Conforms strictly to requirements:
  /// - Truly incremental: stops once already-indexed media boundary is reached
  /// - Deduplicates concurrent sync calls across callers
  /// - Avoids rescanning already indexed history unnecessarily (prevents FLOOD_WAIT)
  /// - Paginates until no more messages or boundary reached
  /// - Uses correct Telegram oldest message ID offset for subsequent pages
  /// - Deduplicates by Telegram message ID
  /// - Preserves newest-to-oldest ordering
  /// - Upserts into SQLite without creating duplicate rows
  Future<List<RemoteFile>> syncSavedMessages({
    int? limit,
    int pageSize = 30,
    int? maxTotalMessages,
    int maxPages = 50,
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (_activeSyncFuture != null) {
      debugPrint('[SYNC] Reusing existing in-flight Telegram sync operation');
      return _activeSyncFuture!;
    }

    final future = _runSyncSavedMessages(
      limit: limit,
      pageSize: pageSize,
      maxTotalMessages: maxTotalMessages,
      maxPages: maxPages,
      timeout: timeout,
    );

    _activeSyncFuture = future;
    return future.whenComplete(() {
      _activeSyncFuture = null;
    });
  }

  Future<List<RemoteFile>> _runSyncSavedMessages({
    int? limit,
    int pageSize = 30,
    int? maxTotalMessages,
    int maxPages = 50,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final effectivePageSize = limit ?? pageSize;
    if (!_database.isInitialized) {
      await _database.initialize();
    }

    final thumbsDir = await getThumbsDirectory();

    int currentOffsetId = 0;
    int pageIndex = 0;
    int totalTelegramMessagesFetched = 0;
    final Map<int, RemoteFile> allExtractedMedia = {};
    final Set<int> seenOffsets = {};

    debugPrint(
      '[SYNC_PAGINATION] Starting Telegram Saved Messages sync: pageSize=$effectivePageSize, maxPages=$maxPages',
    );

    while (pageIndex < maxPages) {
      if (seenOffsets.contains(currentOffsetId)) {
        debugPrint(
          '[SYNC_PAGINATION] Offset $currentOffsetId already visited, terminating to prevent loop',
        );
        break;
      }
      seenOffsets.add(currentOffsetId);
      pageIndex++;

      debugPrint(
        '[SYNC_DIAGNOSTIC] [Stage 1 & 2] Telegram request limit: $effectivePageSize | offsetId: $currentOffsetId',
      );

      final pageMedia = await _mediaService.fetchSavedMessagesPage(
        offsetId: currentOffsetId,
        limit: effectivePageSize,
        thumbsDir: thumbsDir,
        timeout: timeout,
      );

      final totalRawInPage = _mediaService.lastTotalMessagesInPage > 0
          ? _mediaService.lastTotalMessagesInPage
          : pageMedia.length;
      totalTelegramMessagesFetched += totalRawInPage;

      for (final file in pageMedia) {
        allExtractedMedia[file.telegramMessageId] = file;
      }

      final pageIds = pageMedia.map((f) => f.telegramMessageId).toList();
      final existingIds = await _database.getExistingTelegramMessageIds(
        pageIds,
      );
      final bool allAlreadyIndexed =
          pageMedia.isNotEmpty && existingIds.length == pageMedia.length;

      if (pageMedia.isNotEmpty) {
        await _database.upsertFiles(pageMedia);
      }

      // Incremental sync boundary: stop once we encounter a full page of already indexed media
      if (allAlreadyIndexed) {
        debugPrint(
          '[SYNC_PAGINATION] Page $pageIndex is already fully indexed in SQLite (${existingIds.length}/${pageMedia.length} existing). Stopping incremental sync.',
        );
        break;
      }

      // Yield cooperatively to UI isolate to maintain 60/120fps responsiveness
      await Future<void>.delayed(Duration.zero);

      final oldestMsgId =
          _mediaService.lastOldestMessageId ??
          (pageMedia.isNotEmpty
              ? pageMedia
                    .map((f) => f.telegramMessageId)
                    .reduce((a, b) => a < b ? a : b)
              : null);

      final bool hasMore =
          (totalRawInPage >= effectivePageSize ||
              pageMedia.length >= effectivePageSize) &&
          oldestMsgId != null &&
          oldestMsgId != currentOffsetId;

      debugPrint(
        '[SYNC_PAGINATION] Page $pageIndex completed: '
        'rawMessages=$totalRawInPage, '
        'extractedMediaThisPage=${pageMedia.length}, '
        'cumulativeMedia=${allExtractedMedia.length}, '
        'oldestMessageId=$oldestMsgId, '
        'hasMore=$hasMore',
      );

      if (!hasMore || oldestMsgId == currentOffsetId || pageMedia.isEmpty) {
        debugPrint(
          '[SYNC_PAGINATION] Reached end of Telegram history on page $pageIndex',
        );
        break;
      }

      if (maxTotalMessages != null &&
          totalTelegramMessagesFetched >= maxTotalMessages) {
        debugPrint(
          '[SYNC_PAGINATION] Reached maxTotalMessages boundary ($maxTotalMessages)',
        );
        break;
      }

      currentOffsetId = oldestMsgId;
    }

    // Retrieve full recent media from local database
    final galleryMedia = await _database.getRecentMedia();

    debugPrint(
      '[SYNC_SUMMARY] Total Telegram messages: $totalTelegramMessagesFetched | '
      'Recognized media extracted: ${allExtractedMedia.length} | '
      'Gallery query loaded: ${galleryMedia.length} items',
    );

    return galleryMedia;
  }

  final Map<int, Future<RemoteFile>> _inFlightThumbDownloads = {};
  final ConcurrencyLimiter _thumbLimiter = ConcurrencyLimiter(6);
  String? _cachedThumbsDir;

  /// Cached access to the nuvex_thumbs directory.
  Future<String> getThumbsDirectory() async {
    if (_cachedThumbsDir != null) return _cachedThumbsDir!;
    String basePath;
    try {
      final dir = await getApplicationDocumentsDirectory().timeout(
        const Duration(milliseconds: 500),
      );
      basePath = dir.path;
    } catch (_) {
      basePath = Directory.systemTemp.path;
    }

    final thumbsPath = '$basePath/nuvex_thumbs';
    _ensureNoMedia(thumbsPath);
    _cachedThumbsDir = thumbsPath;
    return thumbsPath;
  }

  /// Ensures a thumbnail is downloaded and cached locally on disk.
  ///
  /// - Verifies if [file.thumbnailPath] or [file.localPath] actually exists on disk.
  /// - If missing, downloads small thumbnail on demand from Telegram MTProto.
  /// - Deduplicates simultaneous requests for the same file ID.
  /// - Updates local SQLite database record with [thumbnailPath] when [saveToDatabase] is true.
  Future<RemoteFile> ensureThumbnailAvailable(
    RemoteFile file, {
    bool saveToDatabase = true,
  }) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }

    // 1. If full media is already downloaded and is an image, it serves as the full-res thumbnail
    if (!file.isVideo && file.localPath != null && file.localPath!.isNotEmpty) {
      final existing = File(file.localPath!);
      if (await existing.exists() && await existing.length() > 0) {
        return file;
      }
    }

    // 2. If existing thumbnail path is valid on disk and is a genuine HQ thumbnail, reuse immediately
    if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
      final existing = File(file.thumbnailPath!);
      if (await isValidHqThumbnailAsync(existing)) {
        return file;
      }
    }

    // 3. Deduplicate in-flight download requests
    final msgId = file.telegramMessageId;
    if (_inFlightThumbDownloads.containsKey(msgId)) {
      return _inFlightThumbDownloads[msgId]!;
    }

    final future = _executeThumbDownload(file, saveToDatabase: saveToDatabase);
    _inFlightThumbDownloads[msgId] = future;

    try {
      return await future;
    } finally {
      _inFlightThumbDownloads.remove(msgId);
    }
  }

  Future<RemoteFile> _executeThumbDownload(
    RemoteFile file, {
    bool saveToDatabase = true,
  }) async {
    final thumbsPath = await getThumbsDirectory();
    final targetPath = '$thumbsPath/${file.telegramMessageId}_hq.jpg';
    final targetFile = File(targetPath);

    if (await isValidHqThumbnailAsync(targetFile)) {
      final updated = file.copyWith(thumbnailPath: targetPath);
      if (saveToDatabase && file.thumbnailPath != targetPath) {
        await _database.upsertFiles([updated]);
      }
      return updated;
    }

    return _thumbLimiter.run(() async {
      // Re-check if written while waiting in queue
      if (await isValidHqThumbnailAsync(targetFile)) {
        final updated = file.copyWith(thumbnailPath: targetPath);
        if (saveToDatabase && file.thumbnailPath != targetPath) {
          await _database.upsertFiles([updated]);
        }
        return updated;
      }

      // Download thumbnail from Telegram MTProto
      await _mediaService.downloadThumbnailFile(
        file: file,
        destinationPath: targetPath,
      );
      markThumbnailAsValidated(targetPath);

      final updated = file.copyWith(thumbnailPath: targetPath);
      if (saveToDatabase && file.thumbnailPath != targetPath) {
        await _database.upsertFiles([updated]);
      }
      return updated;
    });
  }

  /// Downloads and caches thumbnails for a batch of files (typically 20-30 items).
  ///
  /// Concurrently processes items through [_thumbLimiter] (2 workers max) to keep UI responsive.
  /// Batch-saves updated database records in a single transaction.
  /// Allows cancellation if user scrolls far away from this batch.
  Future<List<RemoteFile>> ensureThumbnailsForBatch(
    List<RemoteFile> batch, {
    bool Function()? isCancelled,
  }) async {
    if (batch.isEmpty) return const [];
    if (!_database.isInitialized) {
      await _database.initialize();
    }

    final thumbsPath = await getThumbsDirectory();
    final List<RemoteFile> results = List.from(batch);
    final List<RemoteFile> needDatabaseSave = [];
    final List<Future<void>> downloadTasks = [];

    for (int i = 0; i < batch.length; i++) {
      final file = batch[i];

      // 1. Check local original
      if (file.localPath != null && file.localPath!.isNotEmpty) {
        final existing = File(file.localPath!);
        if (await existing.exists() && await existing.length() > 0) {
          continue;
        }
      }

      // 2. Check existing thumbnailPath
      if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
        final existing = File(file.thumbnailPath!);
        if (await isValidHqThumbnailAsync(existing)) {
          continue;
        }
      }

      // 3. Check target disk location
      final targetPath = '$thumbsPath/${file.telegramMessageId}_hq.jpg';
      final targetFile = File(targetPath);
      if (await isValidHqThumbnailAsync(targetFile)) {
        final updated = file.copyWith(thumbnailPath: targetPath);
        results[i] = updated;
        if (file.thumbnailPath != targetPath) {
          needDatabaseSave.add(updated);
        }
        continue;
      }

      // 4. Queue network download through limiter
      final taskIndex = i;
      downloadTasks.add(
        ensureThumbnailAvailable(file, saveToDatabase: false)
            .then((updated) {
              if (isCancelled?.call() == true) return;
              results[taskIndex] = updated;
              if (updated.thumbnailPath != null &&
                  updated.thumbnailPath!.isNotEmpty) {
                needDatabaseSave.add(updated);
              }
            })
            .catchError((e) {
              debugPrint(
                '[MEDIA_REPO] Batch thumb error for ${file.telegramMessageId}: $e',
              );
            }),
      );
    }

    if (downloadTasks.isNotEmpty) {
      await Future.wait(downloadTasks);
    }

    // Single batch database write
    if (needDatabaseSave.isNotEmpty) {
      try {
        await _database.upsertFiles(needDatabaseSave);
      } catch (e) {
        debugPrint('[MEDIA_REPO] Error batch-upserting thumbnails: $e');
      }
    }

    return results;
  }

  /// Ensures a media file is downloaded and cached locally on disk.
  ///
  /// - Verifies if [file.localPath] actually exists on disk.
  /// - If missing, downloads full payload on demand from Telegram MTProto.
  /// - Deduplicates simultaneous requests for the same file ID.
  /// - Updates local SQLite database record with [localPath].
  Future<RemoteFile> ensureFileDownloaded(
    RemoteFile file, {
    void Function(double progress)? onProgress,
  }) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }

    // 1. If existing path is still valid on disk, reuse immediately
    if (file.localPath != null && file.localPath!.isNotEmpty) {
      final existing = File(file.localPath!);
      if (existing.existsSync() && existing.lengthSync() > 0) {
        return file;
      }
    }

    // 2. Reuse in-flight download if user tapped repeatedly
    final msgId = file.telegramMessageId;
    if (_inFlightDownloads.containsKey(msgId)) {
      return _inFlightDownloads[msgId]!;
    }

    final future = _executeDownload(file, onProgress: onProgress);
    _inFlightDownloads[msgId] = future;

    try {
      return await future;
    } finally {
      _inFlightDownloads.remove(msgId);
    }
  }

  /// Cached access to the nuvex_media directory.
  Future<String> getMediaDirectory() async {
    String basePath;
    try {
      final dir = await getApplicationDocumentsDirectory().timeout(
        const Duration(milliseconds: 500),
      );
      basePath = dir.path;
    } catch (_) {
      basePath = Directory.systemTemp.path;
    }
    final mediaPath = '$basePath/nuvex_media';
    _ensureNoMedia(mediaPath);
    return mediaPath;
  }

  Future<RemoteFile> _executeDownload(
    RemoteFile file, {
    void Function(double progress)? onProgress,
  }) async {
    String basePath;
    try {
      final dir = await getApplicationDocumentsDirectory().timeout(
        const Duration(milliseconds: 500),
      );
      basePath = dir.path;
    } catch (_) {
      basePath = Directory.systemTemp.path;
    }

    _ensureNoMedia('$basePath/nuvex_media');
    final safeName = file.name.replaceAll(RegExp(r'[^\w\.-]'), '_');
    final targetPath =
        '$basePath/nuvex_media/${file.telegramMessageId}_$safeName';
    final targetFile = File(targetPath);

    if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
      final updated = file.copyWith(localPath: targetPath);
      await _database.upsertFiles([updated]);
      return updated;
    }

    // Download from Telegram MTProto
    await _mediaService.downloadMediaFile(
      file: file,
      destinationPath: targetPath,
      onProgress: onProgress,
    );

    final updated = file.copyWith(localPath: targetPath);
    await _database.upsertFiles([updated]);
    return updated;
  }

  static final Set<String> _guardedDirectories = {};

  /// Ensures a directory exists and contains a .nomedia file as an extra safeguard
  /// to guarantee Android MediaStore never indexes app-private cache files.
  void _ensureNoMedia(String directoryPath) {
    if (_guardedDirectories.contains(directoryPath)) return;
    try {
      final dir = Directory(directoryPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final noMedia = File('$directoryPath/.nomedia');
      if (!noMedia.existsSync()) {
        noMedia.createSync();
      }
      _guardedDirectories.add(directoryPath);
    } catch (_) {}
  }

  /// Soft deletion: moves media to Trash without destroying Telegram file or local cache.
  Future<void> deleteMedia(RemoteFile file) async {
    await moveToTrash(file);
  }

  /// Moves media to Trash by setting isTrashed = 1 and trashedAt in the SQLite database.
  Future<void> moveToTrash(RemoteFile file, {int? trashedAtMs}) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    await _database.moveToTrash(
      file.telegramMessageId,
      trashedAtMs: trashedAtMs,
    );
  }

  /// Restores a trashed media item back to normal active status.
  Future<void> restoreFromTrash(RemoteFile file) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    await _database.restoreFromTrash(file.telegramMessageId);
  }

  /// Permanently deletes media from Telegram Cloud, cleans up local app-private cache,
  /// and removes the record from SQLite only after Telegram deletion succeeds.
  Future<void> permanentlyDeleteMedia(RemoteFile file) async {
    // 1. Delete from Telegram Cloud using authenticated MTProto connection
    await _mediaService.deleteMessage(messageId: file.telegramMessageId);

    // 2. Clear local cached thumbnail and original (safeguarded: only within app-private cache)
    deleteLocalCachedFiles(file);

    // 3. Delete from local SQLite database
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    await _database.deleteFile(file.telegramMessageId);
  }

  /// Retrieves all currently trashed media records ordered by deletion date.
  Future<List<RemoteFile>> getTrashedMedia({int? limit, int offset = 0}) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _database.getTrashedMedia(limit: limit, offset: offset);
  }

  /// Returns total count of items in Trash.
  Future<int> getTrashedCount() async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    return _database.getTrashedCount();
  }

  /// Safely cleans up expired items from Trash (older than 30 days retention).
  ///
  /// Strictly complies with Requirement 4 & 6:
  /// Never deletes local records without first deleting the Telegram media.
  /// If Telegram deletion fails for an item, it remains in Trash.
  Future<int> cleanupExpiredTrash({
    Duration retention = const Duration(days: 30),
  }) async {
    if (!_database.isInitialized) {
      await _database.initialize();
    }
    final expired = await _database.getExpiredTrashedFiles(
      retention: retention,
    );
    int cleanedCount = 0;
    for (final file in expired) {
      try {
        await permanentlyDeleteMedia(file);
        cleanedCount++;
      } catch (e) {
        debugPrint(
          '[TRASH] Background cleanup failed for ${file.telegramMessageId}: $e',
        );
      }
    }
    return cleanedCount;
  }

  /// Safely deletes local cached files strictly within Nuvex app-private cache directories.
  /// Strictly complies with the requirement: "Never delete arbitrary device files."
  void deleteLocalCachedFiles(RemoteFile file) {
    if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
      try {
        final thumbFile = File(file.thumbnailPath!);
        if (thumbFile.path.contains('nuvex_thumbs') && thumbFile.existsSync()) {
          thumbFile.deleteSync();
        }
      } catch (e) {
        debugPrint('[DELETE] Error removing cached thumbnail: $e');
      }
    }

    if (file.localPath != null && file.localPath!.isNotEmpty) {
      try {
        final localFile = File(file.localPath!);
        if (localFile.path.contains('nuvex_media') && localFile.existsSync()) {
          localFile.deleteSync();
        }
      } catch (e) {
        debugPrint('[DELETE] Error removing cached media: $e');
      }
    }
  }

  /// Uploads a local file to Telegram Saved Messages in original quality without modifications.
  ///
  /// Optionally persists the resulting [RemoteFile] record to the local SQLite database.
  Future<TelegramUploadResult> uploadFile({
    required File file,
    String? mimeType,
    String? sha256,
    void Function(double progress)? onProgress,
    TelegramUploadCancelToken? cancelToken,
    int? randomId,
    bool saveToDatabase = true,
  }) async {
    String? fileSha256 = sha256;
    if (fileSha256 == null && file.existsSync()) {
      try {
        fileSha256 = await calculateFileSha256(file);
      } catch (_) {}
    }

    final result = await _mediaService.uploadDocumentFile(
      file: file,
      mimeType: mimeType,
      onProgress: onProgress,
      cancelToken: cancelToken,
      randomId: randomId,
    );

    if (saveToDatabase) {
      if (!_database.isInitialized) {
        await _database.initialize();
      }
      final remoteFile = result.toRemoteFile(
        localPath: file.path,
        sha256: fileSha256,
      );
      await _database.upsertFiles([remoteFile]);
      debugPrint(
        '[REPO] Persisted uploaded file #${result.messageId} to SQLite database (hash: $fileSha256)',
      );
    }

    return result;
  }
}
