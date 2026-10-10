import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/database/remote_file.dart';
import '../../../core/services/native_media_service.dart';
import '../controllers/media_controller.dart';

/// Modal dialog managing the bulk-share preparation and progress flow for multiple selected files.
///
/// Features:
/// - Awaits and downloads/caches every required original file prior to native sharing.
/// - Never invokes the Android share sheet per-file during download iterations.
/// - Displays real-time preparation progress ("Preparing 20 photos...", "Downloading 7 of 20", progress bar).
/// - Clean cooperative cancellation: stops remaining downloads and dismisses without sharing.
/// - Partial failure resilience: shows clear outcome ("18 of 20 files ready to share") and allows
///   sharing the ready files together in exactly ONE native share sheet invocation.
/// - Zero sharing attempt if cancelled or all downloads fail.
class BulkShareDialog extends StatefulWidget {
  final MediaController controller;
  final VoidCallback? onCompleted;

  const BulkShareDialog({
    super.key,
    required this.controller,
    this.onCompleted,
  });

  @override
  State<BulkShareDialog> createState() => _BulkShareDialogState();
}

class _BulkShareDialogState extends State<BulkShareDialog> {
  late final List<RemoteFile> _targets;
  final List<RemoteFile> _successfulFiles = [];
  final List<RemoteFile> _failedFiles = [];

  bool _isCancelled = false;
  int _currentIndex = 0;
  int _completedCount = 0;
  String _currentFileName = '';
  bool _isFinished = false;

  @override
  void initState() {
    super.initState();
    _targets = List<RemoteFile>.from(widget.controller.selectedFiles);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startBulkShare());
  }

  String _formatCategoryTitle(int count) {
    final allPhotos = _targets.every((f) => f.isPhoto);
    final allVideos = _targets.every((f) => f.isVideo);
    if (allPhotos) {
      return 'Preparing $count ${count == 1 ? 'photo' : 'photos'}...';
    } else if (allVideos) {
      return 'Preparing $count ${count == 1 ? 'video' : 'videos'}...';
    } else {
      return 'Preparing $count ${count == 1 ? 'file' : 'files'}...';
    }
  }

  Future<void> _startBulkShare() async {
    if (_targets.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    for (int i = 0; i < _targets.length; i++) {
      if (_isCancelled || !mounted) break;
      await Future<void>.delayed(Duration.zero);

      final file = _targets[i];
      if (mounted) {
        setState(() {
          _currentIndex = i + 1;
          _currentFileName = file.name;
        });
      }

      RemoteFile readyFile = file;
      try {
        if (readyFile.localPath == null ||
            !File(readyFile.localPath!).existsSync() ||
            File(readyFile.localPath!).lengthSync() == 0) {
          readyFile = await widget.controller.downloadFile(file);
        }

        if (readyFile.localPath != null &&
            File(readyFile.localPath!).existsSync() &&
            File(readyFile.localPath!).lengthSync() > 0) {
          _successfulFiles.add(readyFile);
        } else {
          _failedFiles.add(file);
        }
      } catch (e) {
        debugPrint('[BULK_SHARE] Download failed for ${file.name}: $e');
        _failedFiles.add(file);
      }

      if (mounted) {
        setState(() {
          _completedCount = _successfulFiles.length + _failedFiles.length;
        });
      }
    }

    if (_isCancelled || !mounted) return;

    if (_failedFiles.isEmpty) {
      // All files downloaded successfully: dismiss dialog first, then launch share sheet once
      Navigator.of(context).pop();
      await _executeShare(_successfulFiles);
    } else {
      // Some or all downloads failed: present result UI
      if (mounted) {
        setState(() {
          _isFinished = true;
        });
      }
    }
  }

  void _handleCancel() {
    _isCancelled = true;
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _executeShare(List<RemoteFile> files) async {
    if (files.isEmpty) return;

    final paths = files.map((f) => f.localPath!).toList();
    final mimes = files
        .map(
          (f) => NativeMediaService.resolveMimeType(
            fileName: f.name,
            currentMime: f.mimeType,
            isPhoto: f.isPhoto,
            isVideo: f.isVideo,
          ),
        )
        .toList();

    final allPhotos = files.every((f) => f.isPhoto);
    final allVideos = files.every((f) => f.isVideo);
    final categoryText = allPhotos
        ? 'photos'
        : (allVideos ? 'videos' : 'items');
    final title = 'Share ${files.length} $categoryText';

    try {
      await NativeMediaService.shareFiles(
        filePaths: paths,
        mimeTypes: mimes,
        title: title,
      );
    } catch (e) {
      debugPrint('[BULK_SHARE] Native shareFiles error: $e');
    }

    widget.controller.exitSelectionMode();
    widget.onCompleted?.call();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (!_isFinished) {
            _handleCancel();
          } else {
            Navigator.of(context).pop();
          }
        }
      },
      child: AlertDialog(
        key: const ValueKey('bulk_share_dialog'),
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        actionsPadding: const EdgeInsets.fromLTRB(16, 16, 24, 20),
        title: _buildTitle(),
        content: _buildContent(),
        actions: _buildActions(),
      ),
    );
  }

  Widget _buildTitle() {
    if (_isFinished) {
      if (_successfulFiles.isNotEmpty) {
        return Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.info_outline_rounded,
                color: Color(0xFFD97706),
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${_successfulFiles.length} of ${_targets.length} files ready to share',
                key: const ValueKey('bulk_share_result_title'),
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: NuvexColors.darkNavy,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ],
        );
      } else {
        return Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: NuvexColors.errorRed.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                color: NuvexColors.errorRed,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Sharing Failed',
                key: ValueKey('bulk_share_failed_title'),
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: NuvexColors.darkNavy,
                ),
              ),
            ),
          ],
        );
      }
    }

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: NuvexColors.primaryBlue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.share_rounded,
            color: NuvexColors.primaryBlue,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _formatCategoryTitle(_targets.length),
            key: const ValueKey('bulk_share_title'),
            style: const TextStyle(
              fontFamily: NuvexTypography.primaryFamily,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: NuvexColors.darkNavy,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_isFinished) {
      if (_successfulFiles.isNotEmpty) {
        final failedCount = _failedFiles.length;
        return Text(
          '$failedCount ${failedCount == 1 ? 'file' : 'files'} failed to download. You can still share the ready files together.',
          style: const TextStyle(
            fontFamily: NuvexTypography.primaryFamily,
            fontSize: 14,
            height: 1.4,
            color: NuvexColors.secondaryText,
          ),
        );
      } else {
        return Text(
          'None of the ${_targets.length} selected files could be downloaded.',
          style: const TextStyle(
            fontFamily: NuvexTypography.primaryFamily,
            fontSize: 14,
            height: 1.4,
            color: NuvexColors.secondaryText,
          ),
        );
      }
    }

    final double progress = _targets.isEmpty
        ? 0.0
        : (_completedCount / _targets.length).clamp(0.0, 1.0);
    final displayIndex = _currentIndex == 0 ? 1 : _currentIndex;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Downloading $displayIndex of ${_targets.length}',
              key: const ValueKey('bulk_share_subtitle'),
              style: const TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: NuvexColors.darkNavy,
              ),
            ),
            Text(
              '${(progress * 100).toInt()}%',
              key: const ValueKey('bulk_share_percent_text'),
              style: const TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: NuvexColors.primaryBlue,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            key: const ValueKey('bulk_share_progress'),
            value: progress,
            minHeight: 8,
            backgroundColor: const Color(0xFFE2E8F0),
            valueColor: const AlwaysStoppedAnimation<Color>(
              NuvexColors.primaryBlue,
            ),
          ),
        ),
        if (_currentFileName.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            _currentFileName,
            key: const ValueKey('bulk_share_filename_text'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: NuvexTypography.primaryFamily,
              fontSize: 12,
              color: NuvexColors.secondaryText,
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _buildActions() {
    if (_isFinished) {
      if (_successfulFiles.isNotEmpty) {
        return [
          TextButton(
            key: const ValueKey('bulk_share_fail_cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontWeight: FontWeight.w600,
                color: NuvexColors.secondaryText,
              ),
            ),
          ),
          ElevatedButton(
            key: const ValueKey('bulk_share_share_ready'),
            onPressed: () async {
              Navigator.of(context).pop();
              await _executeShare(_successfulFiles);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: NuvexColors.primaryBlue,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              'Share Ready Files (${_successfulFiles.length})',
              style: const TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ];
      } else {
        return [
          ElevatedButton(
            key: const ValueKey('bulk_share_close'),
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: NuvexColors.darkNavy,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Close',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ];
      }
    }

    return [
      TextButton(
        key: const ValueKey('bulk_share_cancel_button'),
        onPressed: _handleCancel,
        child: const Text(
          'Cancel',
          style: TextStyle(
            fontFamily: NuvexTypography.primaryFamily,
            fontWeight: FontWeight.w600,
            color: NuvexColors.secondaryText,
          ),
        ),
      ),
    ];
  }
}
