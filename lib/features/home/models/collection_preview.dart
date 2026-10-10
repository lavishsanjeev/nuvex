import 'package:flutter/material.dart';

import '../../../core/database/remote_file.dart';

/// Prepared view-model representing a collection card in Nuvex.
///
/// Encapsulates real user-specific collection metadata, thumbnail state,
/// item counts, and fallback visual attributes without querying Telegram
/// directly from UI widgets.
class CollectionPreview {
  /// Category identifier ('documents', 'places', 'stickers', 'moments', etc.).
  final String category;

  /// User-facing display title.
  final String title;

  /// Real item count derived directly from SQLite metadata.
  final int itemCount;

  /// Representative [RemoteFile] matching this collection.
  final RemoteFile? thumbnailRemoteFile;

  /// Local on-disk path to cached thumbnail image.
  final String? thumbnailPath;

  /// Whether a valid local thumbnail image exists.
  bool get hasThumbnail =>
      thumbnailPath != null && thumbnailPath!.trim().isNotEmpty;

  /// Whether thumbnail fetching is in progress.
  final bool isLoading;

  /// Optional error message if thumbnail resolution failed.
  final String? errorMessage;

  /// Fallback outline/rounded icon when no thumbnail exists.
  final IconData fallbackIcon;

  /// Accent color for the fallback icon.
  final Color iconColor;

  /// Background color for the fallback icon badge container.
  final Color badgeBackground;

  const CollectionPreview({
    required this.category,
    required this.title,
    required this.itemCount,
    this.thumbnailRemoteFile,
    this.thumbnailPath,
    this.isLoading = false,
    this.errorMessage,
    required this.fallbackIcon,
    required this.iconColor,
    required this.badgeBackground,
  });

  CollectionPreview copyWith({
    String? category,
    String? title,
    int? itemCount,
    RemoteFile? thumbnailRemoteFile,
    String? thumbnailPath,
    bool? isLoading,
    String? errorMessage,
    IconData? fallbackIcon,
    Color? iconColor,
    Color? badgeBackground,
  }) {
    return CollectionPreview(
      category: category ?? this.category,
      title: title ?? this.title,
      itemCount: itemCount ?? this.itemCount,
      thumbnailRemoteFile: thumbnailRemoteFile ?? this.thumbnailRemoteFile,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage ?? this.errorMessage,
      fallbackIcon: fallbackIcon ?? this.fallbackIcon,
      iconColor: iconColor ?? this.iconColor,
      badgeBackground: badgeBackground ?? this.badgeBackground,
    );
  }
}
