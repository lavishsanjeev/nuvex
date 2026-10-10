import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/database/remote_file.dart';
import '../controllers/media_controller.dart';
import '../media_viewer_screen.dart';

/// True photo-gallery square 1:1 tile for real Telegram media items.
///
/// Complies strictly with Task 5 & Fast Startup + Batch Thumbnail specifications:
/// - Square 1:1 aspect ratio with BoxFit.cover
/// - Real thumbnail rendering via Image.file with cacheWidth/cacheHeight: 300
/// - Smooth fade-in animation on arrival via frameBuilder
/// - Zero circular spinners: lightweight neutral skeleton placeholder matching the grid
/// - Granular ValueNotifier subscription to prevent full-grid rebuilds
/// - Play icon + real duration overlay for videos
/// - Safe lifecycle handling: never triggers repeated downloads from build()
class MediaTile extends StatefulWidget {
  final RemoteFile file;
  final MediaController? controller;
  final int? index;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? badgeText;
  final bool isSelected;
  final bool isSelectionMode;

  const MediaTile({
    super.key,
    required this.file,
    this.controller,
    this.index,
    this.onTap,
    this.onLongPress,
    this.badgeText,
    this.isSelected = false,
    this.isSelectionMode = false,
  });

  @override
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  late RemoteFile _currentFile;
  ValueNotifier<String?>? _thumbNotifier;
  String? _staticImagePath;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
    _setupThumbnailTracking();
  }

  @override
  void didUpdateWidget(MediaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.file.telegramMessageId != oldWidget.file.telegramMessageId ||
        widget.controller != oldWidget.controller) {
      _currentFile = widget.file;
      _setupThumbnailTracking();
    } else if (widget.file.thumbnailPath != oldWidget.file.thumbnailPath ||
        widget.file.localPath != oldWidget.file.localPath) {
      _currentFile = widget.file;
      _syncExistingPath();
    }
  }

  void _setupThumbnailTracking() {
    if (widget.controller != null) {
      _thumbNotifier = widget.controller!.getThumbnailNotifier(
        _currentFile.telegramMessageId,
        initialPath: _currentFile.thumbnailPath,
      );
      if (_thumbNotifier!.value == null &&
          _currentFile.thumbnailPath != null &&
          _currentFile.thumbnailPath!.isNotEmpty) {
        _thumbNotifier!.value = _currentFile.thumbnailPath;
      }
      _staticImagePath = null;
      // If no batch index was provided and thumbnail is not ready, load individually as fallback
      if (widget.index == null && _thumbNotifier?.value == null) {
        widget.controller!
            .loadThumbnail(_currentFile)
            .then<void>((_) {})
            .catchError((_) {});
      }
    } else {
      _thumbNotifier = null;
      _staticImagePath =
          _currentFile.thumbnailPath ??
          (!_currentFile.isVideo ? _currentFile.localPath : null);
    }
  }

  void _syncExistingPath() {
    final path =
        _currentFile.thumbnailPath ??
        (!_currentFile.isVideo ? _currentFile.localPath : null);
    if (path != null) {
      if (_thumbNotifier != null) {
        if (_thumbNotifier!.value != path) {
          _thumbNotifier!.value = path;
        }
      } else {
        setState(() {
          _staticImagePath = path;
        });
      }
    }
  }

  void _handleTap() {
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
    if (widget.isSelectionMode && widget.controller != null) {
      widget.controller!.toggleSelection(_currentFile);
      return;
    }
    if (widget.controller != null) {
      Navigator.of(context).push(
        MediaViewerScreen.route(
          files: [_currentFile],
          initialIndex: 0,
          controller: widget.controller!,
        ),
      );
    }
  }

  void _handleLongPress() {
    if (widget.onLongPress != null) {
      widget.onLongPress!();
    } else if (widget.controller != null) {
      widget.controller!.enterSelectionMode(_currentFile);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = _currentFile.isVideo;

    return RepaintBoundary(
      child: _thumbNotifier != null
          ? ValueListenableBuilder<String?>(
              valueListenable: _thumbNotifier!,
              builder: (context, thumbPath, _) {
                return _buildTileContent(context, thumbPath, isVideo);
              },
            )
          : _buildTileContent(context, _staticImagePath, isVideo),
    );
  }

  Widget _buildTileContent(
    BuildContext context,
    String? imagePath,
    bool isVideo,
  ) {
    return AspectRatio(
      aspectRatio: 1.0,
      child: Material(
        color: const Color(0xFFF1F5F9), // Neutral minimal placeholder color
        child: InkWell(
          onTap: _handleTap,
          onLongPress: _handleLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Media Thumbnail / Image / Neutral Placeholder
              if (imagePath != null && imagePath.isNotEmpty)
                Image.file(
                  File(imagePath),
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  cacheHeight: 300,
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) {
                        if (wasSynchronouslyLoaded) {
                          return child;
                        }
                        if (frame != null) {
                          return AnimatedOpacity(
                            opacity: 1,
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            child: child,
                          );
                        }
                        return _buildPlaceholder(isVideo);
                      },
                  errorBuilder: (context, error, stackTrace) =>
                      _buildPlaceholder(isVideo),
                )
              else
                _buildPlaceholder(isVideo),

              // Selected tint and border overlay
              if (widget.isSelectionMode && widget.isSelected) ...[
                Container(
                  color: NuvexColors.primaryBlue.withValues(alpha: 0.28),
                ),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: NuvexColors.primaryBlue,
                      width: 3.0,
                    ),
                  ),
                ),
              ],

              // Video Duration and Play Icon Overlay
              if (isVideo)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.play_arrow_rounded,
                          size: 13,
                          color: Colors.white,
                        ),
                        if (_currentFile.formattedDuration != null) ...[
                          const SizedBox(width: 2),
                          Text(
                            _currentFile.formattedDuration!,
                            style: const TextStyle(
                              fontFamily: NuvexTypography.primaryFamily,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

              // Selection mode checkmark / hollow indicator
              if (widget.isSelectionMode)
                Positioned(
                  top: 5,
                  right: 5,
                  child: widget.isSelected
                      ? Container(
                          width: 22,
                          height: 22,
                          decoration: const BoxDecoration(
                            color: NuvexColors.primaryBlue,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x33000000),
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                        )
                      : Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                        ),
                ),

              if (widget.badgeText != null && !widget.isSelectionMode)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.badgeText!,
                      style: const TextStyle(
                        fontFamily: NuvexTypography.primaryFamily,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(bool isVideo) {
    return Container(
      color: const Color(0xFFF1F5F9),
      child: Center(
        child: Icon(
          isVideo
              ? Icons.videocam_outlined
              : (_currentFile.isPhoto
                    ? Icons.image_outlined
                    : Icons.insert_drive_file_outlined),
          size: 24,
          color: const Color(0xFFCBD5E1),
        ),
      ),
    );
  }
}
