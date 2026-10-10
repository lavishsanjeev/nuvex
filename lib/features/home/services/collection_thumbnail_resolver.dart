import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/database/remote_file.dart';
import '../models/collection_preview.dart';
import '../repositories/media_repository.dart';

/// Service resolving representative [RemoteFile]s and cached thumbnails for collection cards.
///
/// Implements the pipeline:
/// Collection → real RemoteFile query → matching metadata/filter → representative RemoteFile → existing thumbnail cache → Collection card thumbnail.
///
/// Complies strictly with safety & performance rules:
/// - Never downloads full original media just for card thumbnails
/// - Reuses existing Telegram thumbnails/cache wherever possible
/// - Deduplicates in-flight thumbnail fetches via MediaRepository
class CollectionThumbnailResolver {
  final MediaRepository repository;

  const CollectionThumbnailResolver({required this.repository});

  static const Map<
    String,
    ({String title, IconData icon, Color color, Color bg})
  >
  categoryMetadata = {
    'documents': (
      title: 'Documents',
      icon: Icons.description_outlined,
      color: Color(0xFF2563EB),
      bg: Color(0xFFEFF6FF),
    ),
    'places': (
      title: 'Places',
      icon: Icons.place_outlined,
      color: Color(0xFF059669),
      bg: Color(0xFFECFDF5),
    ),
    'stickers': (
      title: 'Stickers',
      icon: Icons.sentiment_satisfied_alt_outlined,
      color: Color(0xFF7C3AED),
      bg: Color(0xFFF5F3FF),
    ),
    'moments': (
      title: 'Moments',
      icon: Icons.auto_awesome_outlined,
      color: Color(0xFFE11D48),
      bg: Color(0xFFFFF1F2),
    ),
  };

  /// Resolves the representative [RemoteFile] for a collection category.
  Future<RemoteFile?> resolveRepresentative(String category) {
    return repository.getRepresentativeFile(category);
  }

  /// Resolves the thumbnail file path for a representative [RemoteFile].
  ///
  /// Checks local disk cache first. If a valid thumbnail exists, returns its path.
  /// If missing and [autoFetch] is true, triggers on-demand thumbnail download
  /// via [repository.ensureThumbnailAvailable] without downloading full original media.
  Future<String?> resolveThumbnailPath(
    RemoteFile? file, {
    bool autoFetch = true,
  }) async {
    if (file == null) return null;

    // 1. Check existing thumbnail on disk
    if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
      final f = File(file.thumbnailPath!);
      if (f.existsSync() && f.lengthSync() > 0) {
        return file.thumbnailPath;
      }
    }

    // 2. Check existing local full media (if non-video and exists on disk)
    if (!file.isVideo && file.localPath != null && file.localPath!.isNotEmpty) {
      final f = File(file.localPath!);
      if (f.existsSync() && f.lengthSync() > 0) {
        return file.localPath;
      }
    }

    // 3. On-demand thumbnail download (small thumbnail only)
    if (autoFetch) {
      try {
        final updated = await repository.ensureThumbnailAvailable(file);
        if (updated.thumbnailPath != null) {
          final f = File(updated.thumbnailPath!);
          if (f.existsSync() && f.lengthSync() > 0) {
            return updated.thumbnailPath;
          }
        }
      } catch (e) {
        debugPrint(
          '[THUMB_RESOLVER] Error loading thumbnail for ${file.name}: $e',
        );
      }
    }

    return null;
  }

  /// Resolves thumbnail paths for all 4 primary collection cards.
  Future<Map<String, String?>> resolveAllThumbnails({
    bool autoFetch = true,
  }) async {
    final representatives = await repository.getCollectionRepresentatives();
    final Map<String, String?> results = {};

    for (final entry in representatives.entries) {
      final category = entry.key;
      final file = entry.value;
      results[category] = await resolveThumbnailPath(
        file,
        autoFetch: autoFetch,
      );
    }

    return results;
  }

  /// Resolves a complete [CollectionPreview] for a category.
  Future<CollectionPreview> resolveCollectionPreview(
    String category, {
    int? count,
    RemoteFile? representative,
    bool autoFetch = true,
  }) async {
    final meta =
        categoryMetadata[category] ??
        (
          title: category,
          icon: Icons.folder_outlined,
          color: const Color(0xFF2563EB),
          bg: const Color(0xFFEFF6FF),
        );

    final rep = representative ?? await resolveRepresentative(category);
    final thumbPath = await resolveThumbnailPath(rep, autoFetch: autoFetch);
    final itemCount =
        count ?? (await repository.getCachedCollectionCounts())[category] ?? 0;

    return CollectionPreview(
      category: category,
      title: meta.title,
      itemCount: itemCount,
      thumbnailRemoteFile: rep,
      thumbnailPath: thumbPath,
      fallbackIcon: meta.icon,
      iconColor: meta.color,
      badgeBackground: meta.bg,
    );
  }

  /// Resolves all 4 primary collection previews.
  Future<List<CollectionPreview>> resolveAllPreviews({
    bool autoFetch = true,
  }) async {
    final counts = await repository.getCachedCollectionCounts();
    final representatives = await repository.getCollectionRepresentatives();
    final List<CollectionPreview> previews = [];

    for (final category in ['documents', 'places', 'stickers', 'moments']) {
      final rep = representatives[category];
      final thumbPath = await resolveThumbnailPath(rep, autoFetch: autoFetch);
      final meta = categoryMetadata[category]!;

      previews.add(
        CollectionPreview(
          category: category,
          title: meta.title,
          itemCount: counts[category] ?? 0,
          thumbnailRemoteFile: rep,
          thumbnailPath: thumbPath,
          fallbackIcon: meta.icon,
          iconColor: meta.color,
          badgeBackground: meta.bg,
        ),
      );
    }
    return previews;
  }
}
