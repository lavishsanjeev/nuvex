import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'video_range_cache_manager.dart';

/// Detailed breakdown of on-disk cache sizes.
class NuvexCacheInfo {
  final int thumbnailCacheBytes;
  final int videoCacheBytes;
  final int mediaCacheBytes;
  final int totalCacheBytes;

  const NuvexCacheInfo({
    required this.thumbnailCacheBytes,
    required this.videoCacheBytes,
    required this.mediaCacheBytes,
    required this.totalCacheBytes,
  });

  static const NuvexCacheInfo empty = NuvexCacheInfo(
    thumbnailCacheBytes: 0,
    videoCacheBytes: 0,
    mediaCacheBytes: 0,
    totalCacheBytes: 0,
  );
}

/// Service that calculates on-disk cache consumption and performs safe local cache purging.
///
/// CRITICAL ARCHITECTURAL GUARANTEE:
/// Purging local caches NEVER deletes files from Telegram cloud or deletes database index records.
/// It only frees up space on the local filesystem.
class StorageCacheManager {
  final VideoRangeCacheManager _videoCacheManager;
  final String? customBasePath;

  StorageCacheManager({
    VideoRangeCacheManager? videoCacheManager,
    this.customBasePath,
  }) : _videoCacheManager = videoCacheManager ?? VideoRangeCacheManager();

  Future<String> _getBasePath() async {
    if (customBasePath != null) return customBasePath!;
    try {
      final dir = await getApplicationDocumentsDirectory().timeout(
        const Duration(milliseconds: 500),
      );
      return dir.path;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }

  /// Calculates real on-disk cache consumption for thumbnails, video streaming chunks, and downloaded media.
  Future<NuvexCacheInfo> calculateCacheSizes() async {
    final basePath = await _getBasePath();

    final thumbDir = Directory('$basePath/nuvex_thumbs');
    final videoDir = Directory('$basePath/nuvex_stream_cache');
    final mediaDir = Directory('$basePath/nuvex_media');

    final thumbBytes = await _calculateDirectorySize(thumbDir);
    final videoBytes = await _calculateDirectorySize(videoDir);
    final mediaBytes = await _calculateDirectorySize(mediaDir);

    final total = thumbBytes + videoBytes + mediaBytes;

    debugPrint(
      '[CACHE_STATS] Thumbs: ${thumbBytes ~/ 1024} KB | Video: ${videoBytes ~/ 1024} KB | Media: ${mediaBytes ~/ 1024} KB | Total: ${total ~/ 1024} KB',
    );

    return NuvexCacheInfo(
      thumbnailCacheBytes: thumbBytes,
      videoCacheBytes: videoBytes,
      mediaCacheBytes: mediaBytes,
      totalCacheBytes: total,
    );
  }

  /// Safely deletes all local cached thumbnail images.
  Future<void> clearThumbnailCache() async {
    final basePath = await _getBasePath();
    final thumbDir = Directory('$basePath/nuvex_thumbs');
    await _deleteDirectoryContents(thumbDir);
    debugPrint('[CACHE_CLEAR] Thumbnail cache cleared safely');
  }

  /// Safely deletes all local cached video streaming chunks and flushes RAM chunk cache.
  Future<void> clearVideoCache() async {
    final basePath = await _getBasePath();
    final videoDir = Directory('$basePath/nuvex_stream_cache');
    await _deleteDirectoryContents(videoDir);
    _videoCacheManager.clearMemoryCache();
    debugPrint('[CACHE_CLEAR] Video stream cache cleared safely');
  }

  /// Safely purges all local Nuvex caches (thumbnails, video chunks, and full media copies).
  ///
  /// Strictly does NOT delete anything from Telegram cloud.
  Future<void> clearAllCache() async {
    await clearThumbnailCache();
    await clearVideoCache();

    final basePath = await _getBasePath();
    final mediaDir = Directory('$basePath/nuvex_media');
    await _deleteDirectoryContents(mediaDir);

    debugPrint('[CACHE_CLEAR] All local caches cleared safely');
  }

  Future<int> _calculateDirectorySize(Directory dir) async {
    if (!dir.existsSync()) return 0;
    int size = 0;
    try {
      final entities = dir.listSync(recursive: true, followLinks: false);
      for (final entity in entities) {
        if (entity is File) {
          // Do not count the .nomedia safeguard file
          if (entity.path.endsWith('.nomedia')) continue;
          try {
            size += entity.lengthSync();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[CACHE_CALC] Error reading ${dir.path}: $e');
    }
    return size;
  }

  Future<void> _deleteDirectoryContents(Directory dir) async {
    if (!dir.existsSync()) return;
    try {
      final entities = dir.listSync(recursive: false, followLinks: false);
      for (final entity in entities) {
        // Keep .nomedia so Android MediaStore doesn't index subsequent downloads
        if (entity.path.endsWith('.nomedia')) continue;
        try {
          if (entity is File) {
            entity.deleteSync();
          } else if (entity is Directory) {
            entity.deleteSync(recursive: true);
          }
        } catch (e) {
          debugPrint('[CACHE_DELETE] Failed deleting ${entity.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('[CACHE_DELETE] Error listing ${dir.path}: $e');
    }
  }
}
