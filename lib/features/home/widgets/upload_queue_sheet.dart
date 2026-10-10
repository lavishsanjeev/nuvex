import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/database/upload_queue_item.dart';
import '../controllers/upload_controller.dart';

/// Modal bottom sheet displaying the active and historical upload queue.
///
/// Complies strictly with Task 2 & Task 3 requirements:
/// - Displays real filename, formatted size, and status
/// - Shows real-time progress bar for active uploads
/// - Allows cancellation of pending/active uploads
/// - Allows retry of failed or cancelled uploads
/// - Shows clear "Already exists" message for duplicates
class UploadQueueSheet extends StatelessWidget {
  final UploadController controller;

  const UploadQueueSheet({super.key, required this.controller});

  static Future<void> show(BuildContext context, UploadController controller) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => UploadQueueSheet(controller: controller),
    );
  }

  @override
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final queue = controller.queue;

        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Drag Handle ──
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // ── Header ──
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.cloud_upload_outlined,
                          size: 22,
                          color: NuvexColors.darkNavy,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Upload Queue',
                          style: TextStyle(
                            fontFamily: NuvexTypography.primaryFamily,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: NuvexColors.darkNavy,
                            letterSpacing: -0.3,
                          ),
                        ),
                        if (queue.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${queue.length}',
                              style: const TextStyle(
                                fontFamily: NuvexTypography.primaryFamily,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: NuvexColors.primaryBlue,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: NuvexColors.darkNavy,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),

              const Divider(height: 1, color: Color(0xFFE2E8F0)),

              // ── Queue Items List ──
              if (queue.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.check_circle_outline_rounded,
                          size: 44,
                          color: Color(0xFF94A3B8),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'No uploads in queue',
                          style: TextStyle(
                            fontFamily: NuvexTypography.primaryFamily,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: NuvexColors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    itemCount: queue.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (ctx, index) {
                      final item = queue[index];
                      return _QueueItemCard(item: item, controller: controller);
                    },
                  ),
                ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }
}

class _QueueItemCard extends StatelessWidget {
  final UploadQueueItem item;
  final UploadController controller;

  const _QueueItemCard({required this.item, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Icon representation
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _getStatusColor(item.status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _getStatusIcon(item.status),
                  size: 20,
                  color: _getStatusColor(item.status),
                ),
              ),
              const SizedBox(width: 12),

              // File info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: NuvexTypography.primaryFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: NuvexColors.darkNavy,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          item.formattedSize,
                          style: const TextStyle(
                            fontFamily: NuvexTypography.primaryFamily,
                            fontSize: 12,
                            color: NuvexColors.secondaryText,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '•',
                          style: const TextStyle(
                            color: NuvexColors.secondaryText,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _getStatusText(item),
                          style: TextStyle(
                            fontFamily: NuvexTypography.primaryFamily,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _getStatusColor(item.status),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Action buttons (Cancel / Retry)
              if (item.status == UploadStatus.pending ||
                  item.status == UploadStatus.uploading)
                IconButton(
                  key: ValueKey('cancel_upload_${item.id}'),
                  icon: const Icon(
                    Icons.cancel_outlined,
                    color: NuvexColors.secondaryText,
                    size: 22,
                  ),
                  tooltip: 'Cancel upload',
                  onPressed: () => controller.cancelUpload(item.id!),
                ),
              if (item.status == UploadStatus.failed ||
                  item.status == UploadStatus.cancelled)
                IconButton(
                  key: ValueKey('retry_upload_${item.id}'),
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: NuvexColors.primaryBlue,
                    size: 22,
                  ),
                  tooltip: 'Retry upload',
                  onPressed: () => controller.retryUpload(item.id!),
                ),
            ],
          ),

          // Upload progress bar
          if (item.status == UploadStatus.uploading) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: item.progress > 0 ? item.progress : null,
                minHeight: 4,
                backgroundColor: const Color(0xFFE2E8F0),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  NuvexColors.primaryBlue,
                ),
              ),
            ),
          ],

          // Error or duplicate message display
          if (item.errorMessage != null &&
              (item.status == UploadStatus.failed ||
                  item.status == UploadStatus.duplicate)) ...[
            const SizedBox(height: 4),
            Text(
              item.status == UploadStatus.duplicate
                  ? 'Already exists'
                  : item.errorMessage!,
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 11,
                color: item.status == UploadStatus.duplicate
                    ? Colors.amber.shade800
                    : NuvexColors.errorRed,
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getStatusIcon(UploadStatus status) {
    switch (status) {
      case UploadStatus.pending:
        return Icons.hourglass_empty_rounded;
      case UploadStatus.uploading:
        return Icons.cloud_upload_rounded;
      case UploadStatus.completed:
        return Icons.check_circle_rounded;
      case UploadStatus.failed:
        return Icons.error_outline_rounded;
      case UploadStatus.cancelled:
        return Icons.block_rounded;
      case UploadStatus.duplicate:
        return Icons.info_outline_rounded;
    }
  }

  Color _getStatusColor(UploadStatus status) {
    switch (status) {
      case UploadStatus.pending:
        return NuvexColors.secondaryText;
      case UploadStatus.uploading:
        return NuvexColors.primaryBlue;
      case UploadStatus.completed:
        return const Color(0xFF16A34A);
      case UploadStatus.failed:
        return NuvexColors.errorRed;
      case UploadStatus.cancelled:
        return const Color(0xFF64748B);
      case UploadStatus.duplicate:
        return const Color(0xFFD97706);
    }
  }

  String _getStatusText(UploadQueueItem item) {
    switch (item.status) {
      case UploadStatus.pending:
        return 'Pending';
      case UploadStatus.uploading:
        final pct = (item.progress * 100).toInt();
        return 'Uploading ($pct%)';
      case UploadStatus.completed:
        return 'Completed';
      case UploadStatus.failed:
        return 'Failed';
      case UploadStatus.cancelled:
        return 'Cancelled';
      case UploadStatus.duplicate:
        return 'Already exists';
    }
  }
}
