import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../app/theme.dart';
import '../../../core/database/remote_file.dart';
import '../../home/controllers/media_controller.dart';
import '../controllers/locked_folder_controller.dart';

/// Full-screen private media viewer for items inside Nuvex Locked Folder.
///
/// Security & UX Specifications:
/// - Edge-to-edge Google Photos-style dark surface.
/// - Decrypts photo bytes in memory using AES-256-GCM without writing plaintext to disk.
/// - Decrypts video files into isolated private cache with .nomedia and disposes them upon exit.
/// - Automatic dismissal if app backgrounds or folder locks.
/// - Pinch-to-zoom (1.0x to 5.0x), double-tap zoom, and horizontal swipe navigation.
/// - Bottom actions: Restore to Gallery, Delete, and Details.
class LockedMediaViewerScreen extends StatefulWidget {
  final List<RemoteFile> files;
  final int initialIndex;
  final LockedFolderController controller;
  final MediaController mediaController;

  const LockedMediaViewerScreen({
    super.key,
    required this.files,
    required this.initialIndex,
    required this.controller,
    required this.mediaController,
  });

  @override
  State<LockedMediaViewerScreen> createState() => _LockedMediaViewerScreenState();
}

class _LockedMediaViewerScreenState extends State<LockedMediaViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;
  late List<RemoteFile> _files;
  bool _showControls = true;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _files = List<RemoteFile>.from(widget.files);
    _currentIndex = widget.initialIndex.clamp(0, _files.isEmpty ? 0 : _files.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    widget.controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    // If the controller re-locks or master key is cleared (e.g. app backgrounded), exit immediately
    if (!widget.controller.isUnlocked || widget.controller.masterKey == null) {
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _pageController.dispose();
    super.dispose();
  }

  RemoteFile get _currentFile => _files[_currentIndex];

  void _toggleControls() {
    if (_isZoomed) return;
    setState(() {
      _showControls = !_showControls;
    });
  }

  Future<void> _handleRestore() async {
    final file = _currentFile;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Restore to Gallery?'),
        content: Text('Move "${file.name}" back to your public photo library?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: NuvexColors.primaryBlue,
              foregroundColor: Colors.white,
            ),
            child: const Text('Restore'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final restored = await widget.controller.restoreSingleFile(file);
      await widget.mediaController.refreshAfterLockedFolderRestore(
        restoredFiles: [restored],
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restored item to gallery')),
      );

      setState(() {
        _files.removeAt(_currentIndex);
        if (_files.isEmpty) {
          Navigator.of(context).pop();
        } else {
          _currentIndex = _currentIndex.clamp(0, _files.length - 1);
        }
      });
    }
  }

  Future<void> _handleDelete() async {
    final file = _currentFile;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: NuvexColors.errorRed),
            SizedBox(width: 8),
            Text('Permanently Delete?'),
          ],
        ),
        content: Text('Permanently delete "${file.name}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: NuvexColors.errorRed,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await widget.controller.repository.deleteLockedFile(file);
      await widget.controller.reload();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Deleted item'),
          backgroundColor: NuvexColors.errorRed,
        ),
      );

      setState(() {
        _files.removeAt(_currentIndex);
        if (_files.isEmpty) {
          Navigator.of(context).pop();
        } else {
          _currentIndex = _currentIndex.clamp(0, _files.length - 1);
        }
      });
    }
  }

  void _showDetails() {
    final file = _currentFile;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.lock_rounded, size: 20, color: NuvexColors.primaryBlue),
                  SizedBox(width: 8),
                  Text(
                    'Protected Media Details',
                    style: TextStyle(
                      fontFamily: NuvexTypography.primaryFamily,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: NuvexColors.darkNavy,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildDetailRow('File Name', file.name),
              _buildDetailRow('Size', '${(file.sizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB'),
              _buildDetailRow('Type', file.mimeType),
              _buildDetailRow('Status', 'Encrypted with AES-256-GCM'),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: NuvexColors.secondaryText, fontSize: 14)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600, color: NuvexColors.darkNavy, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_files.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. PageView for Media
          PageView.builder(
            controller: _pageController,
            physics: _isZoomed
                ? const NeverScrollableScrollPhysics()
                : const BouncingScrollPhysics(),
            itemCount: _files.length,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
                _isZoomed = false;
              });
            },
            itemBuilder: (context, index) {
              final file = _files[index];
              return _LockedPageItem(
                key: ValueKey(file.telegramMessageId),
                file: file,
                controller: widget.controller,
                onTap: _toggleControls,
                onZoomChanged: (zoomed) {
                  if (_currentIndex == index) {
                    setState(() => _isZoomed = zoomed);
                  }
                },
              );
            },
          ),

          // 2. Top Bar
          if (_showControls)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.75),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.lock_rounded, size: 16, color: NuvexColors.primaryBlue),
                        const SizedBox(width: 6),
                        Text(
                          '${_currentIndex + 1} of ${_files.length}',
                          style: const TextStyle(
                            fontFamily: NuvexTypography.primaryFamily,
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // 3. Bottom Bar
          if (_showControls)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.8),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildAction(
                          icon: Icons.lock_open_rounded,
                          label: 'Restore',
                          onTap: _handleRestore,
                        ),
                        _buildAction(
                          icon: Icons.delete_outline_rounded,
                          label: 'Delete',
                          color: Colors.redAccent,
                          onTap: _handleDelete,
                        ),
                        _buildAction(
                          icon: Icons.info_outline,
                          label: 'Details',
                          onTap: _showDetails,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAction({
    required IconData icon,
    required String label,
    Color color = Colors.white,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LockedPageItem extends StatefulWidget {
  final RemoteFile file;
  final LockedFolderController controller;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;

  const _LockedPageItem({
    super.key,
    required this.file,
    required this.controller,
    required this.onTap,
    required this.onZoomChanged,
  });

  @override
  State<_LockedPageItem> createState() => _LockedPageItemState();
}

class _LockedPageItemState extends State<_LockedPageItem> {
  Uint8List? _photoBytes;
  File? _tempVideoFile;
  VideoPlayerController? _videoController;
  bool _isLoading = true;
  String? _error;
  final TransformationController _transformController = TransformationController();

  @override
  void initState() {
    super.initState();
    _loadMedia();
    _transformController.addListener(_handleZoom);
  }

  void _handleZoom() {
    final scale = _transformController.value.getMaxScaleOnAxis();
    widget.onZoomChanged(scale > 1.05);
  }

  Future<void> _loadMedia() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      if (widget.file.isVideo) {
        final tempFile = await widget.controller.getTempVideoFile(widget.file);
        if (tempFile != null && await tempFile.exists()) {
          _tempVideoFile = tempFile;
          final vc = VideoPlayerController.file(tempFile);
          await vc.initialize();
          vc.setLooping(true);
          vc.play();
          if (mounted) {
            setState(() {
              _videoController = vc;
              _isLoading = false;
            });
          }
        } else {
          if (mounted) setState(() => _error = 'Could not load video');
        }
      } else {
        final bytes = await widget.controller.getMediaBytes(widget.file);
        if (mounted) {
          setState(() {
            _photoBytes = bytes;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Decryption error: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _transformController.removeListener(_handleZoom);
    _transformController.dispose();
    _videoController?.dispose();
    if (_tempVideoFile != null && _tempVideoFile!.existsSync()) {
      try {
        _tempVideoFile!.deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: NuvexColors.primaryBlue),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.white54, size: 48),
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (widget.file.isVideo && _videoController != null && _videoController!.value.isInitialized) {
      return GestureDetector(
        onTap: widget.onTap,
        child: Center(
          child: AspectRatio(
            aspectRatio: _videoController!.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(_videoController!),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      if (_videoController!.value.isPlaying) {
                        _videoController!.pause();
                      } else {
                        _videoController!.play();
                      }
                    });
                  },
                  child: Container(
                    color: Colors.transparent,
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: _videoController!.value.isPlaying ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            size: 48,
                            color: Colors.white,
                          ),
                        ),
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

    if (_photoBytes != null) {
      return GestureDetector(
        onTap: widget.onTap,
        child: InteractiveViewer(
          transformationController: _transformController,
          minScale: 1.0,
          maxScale: 5.0,
          child: Center(
            child: Image.memory(
              _photoBytes!,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const Icon(
                Icons.broken_image,
                size: 64,
                color: Colors.white54,
              ),
            ),
          ),
        ),
      );
    }

    return const Center(
      child: Icon(Icons.description_outlined, size: 64, color: Colors.white54),
    );
  }
}
