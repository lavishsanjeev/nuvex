import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/database/remote_file.dart';
import '../../../core/database/upload_queue_item.dart';
import '../../../telegram/telegram_models.dart';
import '../repositories/upload_repository.dart';

/// Controller coordinating the persistent SQLite upload queue and sequential Telegram uploads.
///
/// Implements Nuvex Upload Queue & Duplicate Detection architecture:
/// - State machine: pending, uploading, completed, failed, cancelled, duplicate
/// - Sequential upload processing strictly one file at a time
/// - Real byte progress tracking (0.0 to 1.0)
/// - Safe cooperative cancellation using TelegramUploadCancelToken
/// - Retry mechanism for failed or cancelled uploads
/// - Queue recovery and persistence across application restarts
/// - Strict SHA-256 duplicate detection before any network bytes are transmitted
class UploadController extends ChangeNotifier {
  final UploadRepository _repository;
  final void Function(RemoteFile remoteFile)? onUploadCompleted;

  UploadController({UploadRepository? repository, this.onUploadCompleted})
    : _repository = repository ?? UploadRepository();

  UploadRepository get repository => _repository;

  List<UploadQueueItem> _queue = [];
  bool _isProcessing = false;
  int? _activeUploadingId;
  TelegramUploadCancelToken? _activeCancelToken;

  List<UploadQueueItem> get queue => List.unmodifiable(_queue);
  bool get isProcessing => _isProcessing;
  int? get activeUploadingId => _activeUploadingId;

  int get pendingCount =>
      _queue.where((i) => i.status == UploadStatus.pending).length;
  int get uploadingCount =>
      _queue.where((i) => i.status == UploadStatus.uploading).length;
  int get failedCount =>
      _queue.where((i) => i.status == UploadStatus.failed).length;
  int get completedCount =>
      _queue.where((i) => i.status == UploadStatus.completed).length;

  bool get hasActiveOrPending => _queue.any(
    (i) =>
        i.status == UploadStatus.pending || i.status == UploadStatus.uploading,
  );

  /// Initializes queue by recovering interrupted uploads and loading persisted items.
  Future<void> initialize() async {
    try {
      await _repository.recoverInterruptedUploads();
      await loadQueue();
      // Start processing if any items were pending or recovered
      _processNextInQueue();
    } catch (e) {
      debugPrint('[UPLOAD_CONTROLLER] Error initializing upload queue: $e');
    }
  }

  /// Reloads queue items from the SQLite database.
  Future<void> loadQueue() async {
    try {
      _queue = await _repository.getQueueItems();
      notifyListeners();
    } catch (e) {
      debugPrint('[UPLOAD_CONTROLLER] Error loading queue from DB: $e');
    }
  }

  /// Enqueues a single file into the persistent queue and starts processing.
  Future<UploadQueueItem> enqueueFile(File file, {String? mimeType}) async {
    final item = await _repository.enqueueFile(file, mimeType: mimeType);
    await loadQueue();
    _processNextInQueue();
    return item;
  }

  /// Enqueues multiple files at once into the persistent queue and starts processing.
  Future<List<UploadQueueItem>> enqueueFiles(List<File> files) async {
    final List<UploadQueueItem> added = [];
    for (final file in files) {
      try {
        final item = await _repository.enqueueFile(file);
        added.add(item);
      } catch (e) {
        debugPrint('[UPLOAD_CONTROLLER] Failed to enqueue ${file.path}: $e');
      }
    }
    await loadQueue();
    _processNextInQueue();
    return added;
  }

  /// Cancels an in-progress or pending upload item safely.
  Future<void> cancelUpload(int id) async {
    if (_activeUploadingId == id && _activeCancelToken != null) {
      _activeCancelToken?.cancel('Cancelled by user');
    }

    final index = _queue.indexWhere((i) => i.id == id);
    if (index != -1) {
      final updated = _queue[index].copyWith(
        status: UploadStatus.cancelled,
        errorMessage: 'Cancelled by user',
        updatedAt: DateTime.now(),
      );
      await _repository.database.updateUploadQueueItem(updated);
      _queue[index] = updated;
      notifyListeners();
    }
  }

  /// Retries a failed or cancelled upload.
  Future<void> retryUpload(int id) async {
    final index = _queue.indexWhere((i) => i.id == id);
    if (index != -1) {
      final updated = _queue[index].copyWith(
        status: UploadStatus.pending,
        progress: 0.0,
        errorMessage: null,
        updatedAt: DateTime.now(),
      );
      await _repository.database.updateUploadQueueItem(updated);
      _queue[index] = updated;
      notifyListeners();
      _processNextInQueue();
    }
  }

  /// Sequential upload processor loop.
  /// Ensures strictly one upload runs at a time in chronological order.
  Future<void> _processNextInQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      while (true) {
        // Find the oldest pending item
        final pending = _queue
            .where((i) => i.status == UploadStatus.pending)
            .toList();
        if (pending.isEmpty) break;

        final nextItem = pending.first;
        await _executeUpload(nextItem);
      }
    } finally {
      _isProcessing = false;
      _activeUploadingId = null;
      _activeCancelToken = null;
      notifyListeners();
    }
  }

  /// Executes upload pipeline for a single queue item:
  /// 1. Calculate original file SHA-256
  /// 2. Check for duplicate against existing records
  /// 3. Upload sequentially via TelegramMediaService
  /// 4. Update status and notify callbacks
  Future<void> _executeUpload(UploadQueueItem item) async {
    final file = File(item.filePath);
    if (!file.existsSync()) {
      final failed = item.copyWith(
        status: UploadStatus.failed,
        errorMessage: 'File not found on disk',
        updatedAt: DateTime.now(),
      );
      await _repository.database.updateUploadQueueItem(failed);
      await loadQueue();
      return;
    }

    // ── Stage 1: Calculate SHA-256 from ORIGINAL file bytes ──
    String hash;
    try {
      hash = await _repository.calculateSha256(file);
    } catch (e) {
      final failed = item.copyWith(
        status: UploadStatus.failed,
        errorMessage: 'Failed to compute SHA-256: $e',
        updatedAt: DateTime.now(),
      );
      await _repository.database.updateUploadQueueItem(failed);
      await loadQueue();
      return;
    }

    // Update item with SHA-256 hash
    item = item.copyWith(sha256: hash);
    await _repository.database.updateUploadQueueItem(item);

    // ── Stage 2: Duplicate Detection ──
    final isDuplicate = await _repository.hasDuplicateHash(hash);
    if (isDuplicate) {
      debugPrint(
        '[DUPLICATE_DETECTION] Duplicate found for ${item.fileName} ($hash). Skipping upload.',
      );
      final duplicateItem = item.copyWith(
        status: UploadStatus.duplicate,
        errorMessage: 'Already exists',
        updatedAt: DateTime.now(),
      );
      await _repository.database.updateUploadQueueItem(duplicateItem);
      await loadQueue();
      return;
    }

    // ── Stage 3: Sequential Upload to Telegram ──
    _activeUploadingId = item.id;
    final cancelToken = TelegramUploadCancelToken();
    _activeCancelToken = cancelToken;

    var uploadingItem = item.copyWith(
      status: UploadStatus.uploading,
      progress: 0.0,
      updatedAt: DateTime.now(),
    );
    await _repository.database.updateUploadQueueItem(uploadingItem);
    await loadQueue();

    try {
      final remoteFile = await _repository.uploadQueueItem(
        item: uploadingItem,
        onProgress: (p) {
          uploadingItem = uploadingItem.copyWith(progress: p);
          final idx = _queue.indexWhere((q) => q.id == item.id);
          if (idx != -1) {
            _queue[idx] = uploadingItem;
            notifyListeners();
          }
        },
        cancelToken: cancelToken,
      );

      final completedItem = uploadingItem.copyWith(
        status: UploadStatus.completed,
        progress: 1.0,
        telegramMessageId: remoteFile.telegramMessageId,
        updatedAt: DateTime.now(),
      );
      await _repository.database.updateUploadQueueItem(completedItem);
      onUploadCompleted?.call(remoteFile);
      await loadQueue();
    } on TelegramUploadCancelledException {
      final cancelledItem = uploadingItem.copyWith(
        status: UploadStatus.cancelled,
        errorMessage: 'Cancelled',
        updatedAt: DateTime.now(),
      );
      await _repository.database.updateUploadQueueItem(cancelledItem);
      await loadQueue();
    } catch (e) {
      final failedItem = uploadingItem.copyWith(
        status: UploadStatus.failed,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
        updatedAt: DateTime.now(),
      );
      await _repository.database.updateUploadQueueItem(failedItem);
      await loadQueue();
    }
  }
}
