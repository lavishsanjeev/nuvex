import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/database/remote_file.dart';
import '../../../core/services/native_media_service.dart';
import '../../locked_folder/controllers/locked_folder_controller.dart';
import '../../locked_folder/repositories/locked_folder_repository.dart';
import '../../locked_folder/services/locked_folder_auth_service.dart';
import '../models/collection_preview.dart';
import '../repositories/media_repository.dart';
import '../services/collection_thumbnail_resolver.dart';
import '../services/thumbnail_batch_manager.dart';
import 'upload_controller.dart';

/// Distinct statuses of media sync and database cache loading.
enum MediaLoadingStatus {
  /// Uninitialized state before reading cache.
  initial,

  /// Actively loading or synchronizing from Telegram.
  loading,

  /// Data successfully loaded from local DB or Telegram.
  loaded,

  /// An error occurred with retry capability.
  error,
}

/// Controller driving local-first media presentation and Telegram synchronization.
///
/// Complies strictly with Task 5 requirements:
/// - Reuses existing authenticated session
/// - Loads from SQLite DB cache first for zero UI freeze
/// - Paginated background sync from Telegram Saved Messages
/// - Real database-derived collection counts
/// - Proper loading, empty, error, and retry states
class MediaController extends ChangeNotifier {
  static final MediaController _instance = MediaController._internal();
  factory MediaController({
    MediaRepository? repository,
    UploadController? uploadController,
    LockedFolderController? lockedFolderController,
  }) {
    if (repository != null ||
        uploadController != null ||
        lockedFolderController != null) {
      return MediaController._internal(
        repository: repository,
        uploadController: uploadController,
        lockedFolderController: lockedFolderController,
      );
    }
    return _instance;
  }
  MediaController._internal({
    MediaRepository? repository,
    UploadController? uploadController,
    LockedFolderController? lockedFolderController,
  }) : _repository = repository ?? MediaRepository() {
    _uploadController =
        uploadController ??
        UploadController(
          repository: _repository.uploadRepository,
          onUploadCompleted: _onUploadCompleted,
        );
    _uploadController.addListener(_onUploadQueueChanged);
    _lockedFolderController =
        lockedFolderController ??
        LockedFolderController(
          authService: LockedFolderAuthService(),
          repository: LockedFolderRepository(
            database: _repository.database,
            mediaRepository: _repository,
          ),
        );
  }

  final MediaRepository _repository;
  late final UploadController _uploadController;
  late final LockedFolderController _lockedFolderController;

  MediaRepository get repository => _repository;
  UploadController get uploadController => _uploadController;
  LockedFolderController get lockedFolderController => _lockedFolderController;

  void _onUploadCompleted(RemoteFile remoteFile) async {
    final idx = _recentMedia.indexWhere(
      (f) => f.telegramMessageId == remoteFile.telegramMessageId,
    );
    if (idx == -1) {
      _recentMedia.insert(0, remoteFile);
    } else {
      _recentMedia[idx] = remoteFile;
    }
    try {
      _collectionCounts = await _repository.getCachedCollectionCounts();
    } catch (_) {}
    notifyListeners();
  }

  int _lastPendingCount = 0;
  int _lastUploadingCount = 0;
  bool _lastHasActive = false;

  void _onUploadQueueChanged() {
    final hasActive = _uploadController.hasActiveOrPending;
    final pending = _uploadController.pendingCount;
    final uploading = _uploadController.uploadingCount;
    if (hasActive != _lastHasActive ||
        pending != _lastPendingCount ||
        uploading != _lastUploadingCount) {
      _lastHasActive = hasActive;
      _lastPendingCount = pending;
      _lastUploadingCount = uploading;
      notifyListeners();
    }
  }

  late final CollectionThumbnailResolver _thumbnailResolver =
      CollectionThumbnailResolver(repository: _repository);
  CollectionThumbnailResolver get thumbnailResolver => _thumbnailResolver;

  MediaLoadingStatus _status = MediaLoadingStatus.initial;
  List<RemoteFile> _recentMedia = [];
  Map<String, int> _collectionCounts = {};
  Map<String, String?> _collectionThumbnails = {};
  List<CollectionPreview> _collectionPreviews = [];
  String? _errorMessage;
  bool _isSyncing = false;
  DateTime? _lastSyncTime;

  // â”€â”€ Batch Thumbnail Loading Manager â”€â”€
  late final ThumbnailBatchManager _batchManager = ThumbnailBatchManager(
    repository: _repository,
    batchSize: 24,
    maxConcurrent: 6,
    onThumbnailLoaded: _onThumbnailLoaded,
  );

  ThumbnailBatchManager get batchManager => _batchManager;

  void _onThumbnailLoaded(int messageId, String path) {
    final index = _recentMedia.indexWhere(
      (f) => f.telegramMessageId == messageId,
    );
    if (index != -1 && _recentMedia[index].thumbnailPath != path) {
      _recentMedia[index] = _recentMedia[index].copyWith(thumbnailPath: path);
    }
  }

  /// Returns a granular [ValueNotifier] for a specific media item's thumbnail.
  /// Allows individual [MediaTile] widgets to rebuild without rebuilding the entire grid.
  ValueNotifier<String?> getThumbnailNotifier(
    int messageId, {
    String? initialPath,
  }) => _batchManager.getNotifier(messageId, initialPath: initialPath);

  /// Requests loading and caching of thumbnails in batches of ~24 items.
  void requestThumbnailBatchForIndex(int index, {int scrollDirection = 0}) {
    _batchManager.requestBatchForIndex(
      index,
      _recentMedia,
      scrollDirection: scrollDirection,
    );
  }

  // â”€â”€ Multi-Select Mode State â”€â”€
  bool _isSelectionMode = false;
  final Set<int> _selectedMessageIds = {};

  bool get isSelectionMode => _isSelectionMode;
  int get selectedCount => _selectedMessageIds.length;
  Set<int> get selectedMessageIds => Set.unmodifiable(_selectedMessageIds);
  bool isFileSelected(int messageId) => _selectedMessageIds.contains(messageId);

  List<RemoteFile> get selectedFiles => _recentMedia
      .where((f) => _selectedMessageIds.contains(f.telegramMessageId))
      .toList();

  void enterSelectionMode([RemoteFile? initialFile]) {
    _isSelectionMode = true;
    _selectedMessageIds.clear();
    if (initialFile != null) {
      _selectedMessageIds.add(initialFile.telegramMessageId);
    }
    notifyListeners();
  }

  void toggleSelection(RemoteFile file) {
    if (_selectedMessageIds.contains(file.telegramMessageId)) {
      _selectedMessageIds.remove(file.telegramMessageId);
    } else {
      _selectedMessageIds.add(file.telegramMessageId);
    }
    notifyListeners();
  }

  void selectAll([List<RemoteFile>? files]) {
    final targets = files ?? _recentMedia;
    _selectedMessageIds.addAll(targets.map((f) => f.telegramMessageId));
    notifyListeners();
  }

  void deselectAll() {
    _selectedMessageIds.clear();
    notifyListeners();
  }

  void exitSelectionMode() {
    _isSelectionMode = false;
    _selectedMessageIds.clear();
    notifyListeners();
  }

  MediaLoadingStatus get status => _status;
  List<RemoteFile> get recentMedia => _recentMedia;
  Map<String, int> get collectionCounts => _collectionCounts;
  Map<String, String?> get collectionThumbnails => _collectionThumbnails;
  List<CollectionPreview> get collectionPreviews => _collectionPreviews;
  String? get errorMessage => _errorMessage;
  bool get isSyncing => _isSyncing;
  bool get isLoading => _status == MediaLoadingStatus.loading;
  bool get isLoaded => _status == MediaLoadingStatus.loaded;
  bool get hasError => _status == MediaLoadingStatus.error;
  bool get isEmpty =>
      _status == MediaLoadingStatus.loaded && _recentMedia.isEmpty;

  /// Retrieves the prepared preview for a specific collection category.
  CollectionPreview? getPreviewForCategory(String category) {
    for (final p in _collectionPreviews) {
      if (p.category == category) return p;
    }
    return null;
  }

  /// Resolves real thumbnail image paths and previews for primary collection cards.
  Future<void> loadCollectionThumbnails({bool autoFetch = true}) async {
    try {
      if (!_repository.database.isInitialized) return;
      final previews = await _repository.getPrimaryCollectionPreviews(
        autoFetchThumb: autoFetch,
      );
      _collectionPreviews = previews;
      final Map<String, String?> thumbs = {};
      final Map<String, int> counts = Map.of(_collectionCounts);
      for (final p in previews) {
        thumbs[p.category] = p.thumbnailPath;
        counts[p.category] = p.itemCount;
      }
      _collectionThumbnails = thumbs;
      _collectionCounts = counts;
      notifyListeners();
    } catch (e) {
      debugPrint('[MEDIA] Error loading collection thumbnails: $e');
    }
  }

  /// Loads cached data from SQLite database first, then triggers background sync.
  Future<void> initializeAndSync() async {
    if (_status == MediaLoadingStatus.loaded && _recentMedia.isNotEmpty) {
      // Data already in memory; check if background sync is needed
      final now = DateTime.now();
      if (_lastSyncTime != null &&
          now.difference(_lastSyncTime!).inMinutes < 5) {
        return;
      }
    }

    // 1. Initialize persistent upload queue and recover interrupted items
    unawaited(_uploadController.initialize());

    // 2. Read SQLite DB cache immediately (zero latency)
    await loadCacheOnly();

    // 3. Trigger asynchronous background Telegram sync
    await syncMedia();
  }

  /// Loads cached media and collection counts directly from SQLite DB without network.
  Future<void> loadCacheOnly() async {
    try {
      final cached = await _repository.getCachedRecentMedia(limit: null);
      final counts = await _repository.getCachedCollectionCounts();

      _recentMedia = cached;
      _collectionCounts = counts;
      _batchManager.reset();

      try {
        final previews = await _repository.getPrimaryCollectionPreviews(
          autoFetchThumb: false,
        );
        _collectionPreviews = previews;
        final Map<String, String?> thumbs = {};
        for (final p in previews) {
          thumbs[p.category] = p.thumbnailPath;
        }
        _collectionThumbnails = thumbs;
      } catch (_) {}

      debugPrint(
        '[CONTROLLER_DIAGNOSTIC] loadCacheOnly: loaded ${_recentMedia.length} items from SQLite cache',
      );

      if (_recentMedia.isNotEmpty) {
        _status = MediaLoadingStatus.loaded;
      }
      notifyListeners();

      if (_recentMedia.isNotEmpty) {
        await _batchManager.onMediaListUpdated(_recentMedia);
      }
    } catch (e) {
      debugPrint('[MEDIA] Error loading local DB cache: $e');
    }
  }

  /// Synchronizes newest media metadata from Telegram Saved Messages.
  Future<void> syncMedia({
    bool isRetry = false,
    int pageSize = 30,
    int maxPages = 50,
  }) async {
    if (_isSyncing) return;

    _isSyncing = true;
    _errorMessage = null;

    if (_recentMedia.isEmpty) {
      _status = MediaLoadingStatus.loading;
    }
    notifyListeners();

    try {
      final updatedMedia = await _repository.syncSavedMessages(
        pageSize: pageSize,
        maxPages: maxPages,
        timeout: const Duration(seconds: 15),
      );
      final counts = await _repository.getCachedCollectionCounts();

      final bool hasNewItems =
          updatedMedia.length != _recentMedia.length ||
          (updatedMedia.isNotEmpty &&
              _recentMedia.isNotEmpty &&
              updatedMedia.first.telegramMessageId !=
                  _recentMedia.first.telegramMessageId);

      _recentMedia = updatedMedia;
      _collectionCounts = counts;
      if (hasNewItems) {
        _batchManager.reset();
      }

      try {
        final previews = await _repository.getPrimaryCollectionPreviews(
          autoFetchThumb: true,
        );
        _collectionPreviews = previews;
        final Map<String, String?> thumbs = {};
        for (final p in previews) {
          thumbs[p.category] = p.thumbnailPath;
        }
        _collectionThumbnails = thumbs;
      } catch (_) {}
      _status = MediaLoadingStatus.loaded;
      _lastSyncTime = DateTime.now();
      _errorMessage = null;

      debugPrint(
        '[CONTROLLER_DIAGNOSTIC] [Stage 7] Loaded ${_recentMedia.length} media items into active gallery state',
      );
    } on SocketException catch (e) {
      debugPrint('[MEDIA] Sync network error: $e');
      if (_recentMedia.isEmpty) {
        _status = MediaLoadingStatus.error;
        _errorMessage = 'Unable to connect to cloud storage. Please check your internet connection.';
      }
    } on TimeoutException catch (e) {
      debugPrint('[MEDIA] Sync timeout: $e');
      if (_recentMedia.isEmpty) {
        _status = MediaLoadingStatus.error;
        _errorMessage = 'Connection timed out while syncing. Please tap retry.';
      }
    } catch (e) {
      debugPrint('[MEDIA] Sync error: $e');
      if (_recentMedia.isEmpty) {
        _status = MediaLoadingStatus.error;
        _errorMessage =
            'Unable to sync: ${e.toString().replaceAll('Exception: ', '')}';
      }
    } finally {
      _isSyncing = false;
      // Guaranteed safety: if still loading, set to loaded or error
      if (_status == MediaLoadingStatus.loading) {
        _status = _recentMedia.isNotEmpty
            ? MediaLoadingStatus.loaded
            : MediaLoadingStatus.loaded;
      }
      notifyListeners();

      if (_recentMedia.isNotEmpty) {
        unawaited(_batchManager.onMediaListUpdated(_recentMedia));
      }
    }
  }

  DateTime? _lastRetryTime;

  /// Retries syncing after an error with a cooldown to prevent tight retry loops.
  Future<void> retry() {
    final now = DateTime.now();
    if (_lastRetryTime != null &&
        now.difference(_lastRetryTime!).inMilliseconds < 1500) {
      return Future.value();
    }
    _lastRetryTime = now;
    return syncMedia(isRetry: true);
  }

  /// Downloads and caches a media file on demand, updating local state.
  Future<RemoteFile> downloadFile(
    RemoteFile file, {
    void Function(double progress)? onProgress,
  }) async {
    final downloaded = await _repository.ensureFileDownloaded(
      file,
      onProgress: onProgress,
    );
    final index = _recentMedia.indexWhere(
      (f) => f.telegramMessageId == file.telegramMessageId,
    );
    if (index != -1) {
      _recentMedia[index] = downloaded;
      notifyListeners();
    }
    return downloaded;
  }

  /// Ensures a thumbnail is available on disk, updating local state and database.
  Future<RemoteFile> loadThumbnail(RemoteFile file) async {
    try {
      final updated = await _repository.ensureThumbnailAvailable(file);
      if (updated.thumbnailPath != null && updated.thumbnailPath!.isNotEmpty) {
        _batchManager.getNotifier(file.telegramMessageId).value =
            updated.thumbnailPath;
        _onThumbnailLoaded(file.telegramMessageId, updated.thumbnailPath!);
      }
      return updated;
    } catch (e) {
      debugPrint('[MEDIA] Error loading thumbnail for ${file.name}: $e');
      return file;
    }
  }

  /// Moves a media item to Trash, removing it from normal Photos and Collections immediately.
  /// Complies with Trash architecture: Telegram file and local cache remain intact.
  Future<void> moveToTrash(RemoteFile file, {int? trashedAtMs}) async {
    await _repository.deleteMedia(file);

    _recentMedia.removeWhere(
      (f) => f.telegramMessageId == file.telegramMessageId,
    );

    try {
      _collectionCounts = await _repository.getCachedCollectionCounts();
    } catch (e) {
      debugPrint('[MEDIA] Error refreshing collection counts after trash: $e');
    }

    notifyListeners();

    final affectsCollectionThumb = _collectionPreviews.any(
      (p) => p.thumbnailRemoteFile?.telegramMessageId == file.telegramMessageId,
    );
    if (affectsCollectionThumb) {
      try {
        await loadCollectionThumbnails(autoFetch: false);
      } catch (_) {}
    }
  }

  /// Alias for moveToTrash to preserve backward compatibility with existing callers.
  Future<void> deleteMedia(RemoteFile file) async => moveToTrash(file);

  /// Restores a trashed media item back to active Photos and Collections.
  Future<void> restoreFromTrash(RemoteFile file) async {
    await _repository.restoreFromTrash(file);

    try {
      _recentMedia = await _repository.getCachedRecentMedia(limit: null);
      _collectionCounts = await _repository.getCachedCollectionCounts();
    } catch (e) {
      debugPrint('[MEDIA] Error refreshing media after restore: $e');
    }

    notifyListeners();

    try {
      await loadCollectionThumbnails(autoFetch: false);
    } catch (_) {}
  }

  /// Refreshes the gallery immediately after one or more files are restored from the Locked Folder.
  ///
  /// - Reads fresh SQLite cache including the restored items (now having isLocked = 0).
  /// - Updates thumbnail notifiers so MediaTile instances immediately render the restored thumbnail.
  /// - Triggers background thumbnail generation if needed.
  /// - Notifies all gallery listeners without requiring an app restart.
  Future<void> refreshAfterLockedFolderRestore({
    List<RemoteFile>? restoredFiles,
  }) async {
    try {
      final cached = await _repository.getCachedRecentMedia(limit: null);
      final counts = await _repository.getCachedCollectionCounts();

      _recentMedia = cached;
      _collectionCounts = counts;

      // Update thumbnail notifiers for the restored items
      if (restoredFiles != null && restoredFiles.isNotEmpty) {
        for (final file in restoredFiles) {
          final thumb = file.thumbnailPath ??
              (!file.isVideo && file.localPath != null ? file.localPath : null);
          if (thumb != null && thumb.isNotEmpty) {
            _batchManager.getNotifier(file.telegramMessageId).value = thumb;
            _onThumbnailLoaded(file.telegramMessageId, thumb);
          } else {
            // Ensure thumbnail exists in background
            unawaited(_repository.ensureThumbnailAvailable(file).then((updated) {
              if (updated.thumbnailPath != null) {
                _batchManager.getNotifier(file.telegramMessageId).value =
                    updated.thumbnailPath;
                _onThumbnailLoaded(
                  file.telegramMessageId,
                  updated.thumbnailPath!,
                );
              }
            }));
          }
        }
      } else {
        // Also ensure any restored items in _recentMedia have their thumbnails linked
        for (final file in _recentMedia) {
          if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
            _batchManager.getNotifier(file.telegramMessageId).value =
                file.thumbnailPath;
          }
        }
      }

      try {
        await loadCollectionThumbnails(autoFetch: false);
      } catch (_) {}

      notifyListeners();
    } catch (e) {
      debugPrint('[MEDIA] Error refreshing after locked folder restore: $e');
    }
  }

  /// Permanently deletes media from Telegram, local cache, and SQLite database.
  Future<void> permanentlyDeleteMedia(RemoteFile file) async {
    await _repository.permanentlyDeleteMedia(file);

    _recentMedia.removeWhere(
      (f) => f.telegramMessageId == file.telegramMessageId,
    );

    try {
      _collectionCounts = await _repository.getCachedCollectionCounts();
    } catch (e) {
      debugPrint(
        '[MEDIA] Error refreshing collection counts after permanent delete: $e',
      );
    }

    notifyListeners();

    final affectsCollectionThumb = _collectionPreviews.any(
      (p) => p.thumbnailRemoteFile?.telegramMessageId == file.telegramMessageId,
    );
    if (affectsCollectionThumb) {
      try {
        await loadCollectionThumbnails(autoFetch: false);
      } catch (_) {}
    }
  }

  /// Safely cleans up expired items from Trash in the background (older than 30 days retention).
  Future<int> cleanupExpiredTrash() async {
    final cleaned = await _repository.cleanupExpiredTrash();
    if (cleaned > 0) {
      try {
        _collectionCounts = await _repository.getCachedCollectionCounts();
        notifyListeners();
      } catch (_) {}
    }
    return cleaned;
  }

  // â”€â”€ Multi-Select Bulk Actions â”€â”€

  /// Bulk moves selected files to trash.
  /// Automatically exits selection mode upon completion.
  Future<int> deleteSelected() async {
    final targets = selectedFiles;
    if (targets.isEmpty) {
      exitSelectionMode();
      return 0;
    }

    int count = 0;
    for (final file in targets) {
      await moveToTrash(file);
      count++;
    }
    exitSelectionMode();
    return count;
  }

  /// Bulk saves selected files to device user-visible gallery/downloads.
  /// Does not download full media unnecessarily.
  /// Automatically exits selection mode upon completion.
  Future<List<String>> saveSelected() async {
    final targets = selectedFiles;
    if (targets.isEmpty) {
      exitSelectionMode();
      return [];
    }

    final List<String> savedPaths = [];
    for (final file in targets) {
      RemoteFile readyFile = file;
      bool needsDownload = true;
      if (readyFile.localPath != null && readyFile.localPath!.isNotEmpty) {
        final f = File(readyFile.localPath!);
        if (await f.exists() && await f.length() > 0) {
          needsDownload = false;
        }
      }

      if (needsDownload) {
        // Download on-demand only because user explicitly requested saving
        readyFile = await downloadFile(file);
      }

      if (readyFile.localPath != null) {
        final f = File(readyFile.localPath!);
        if (await f.exists()) {
          try {
            final path = await NativeMediaService.saveToDevice(
              filePath: readyFile.localPath!,
              fileName: readyFile.name,
              mimeType: readyFile.mimeType,
              category: readyFile.category,
            );
            savedPaths.add(path);
          } catch (e) {
            debugPrint('[MEDIA] Error saving ${readyFile.name}: $e');
          }
        }
      }
    }

    exitSelectionMode();
    return savedPaths;
  }

  /// Bulk shares selected files using native share sheet.
  /// Downloads and caches all required files first.
  /// Awaits all downloads before calling the native share API exactly ONCE.
  /// If [isCancelled] returns true, halts remaining downloads and exits without sharing.
  /// Automatically exits selection mode upon completion.
  Future<bool> shareSelected({
    void Function(int current, int total, String fileName)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final targets = List<RemoteFile>.from(selectedFiles);
    if (targets.isEmpty) {
      exitSelectionMode();
      return false;
    }

    final List<String> readyPaths = [];
    final List<String> readyMimes = [];
    bool allSuccess = true;

    for (int i = 0; i < targets.length; i++) {
      if (isCancelled?.call() == true) {
        return false;
      }
      final file = targets[i];
      onProgress?.call(i + 1, targets.length, file.name);

      RemoteFile readyFile = file;
      bool needsDownload = true;
      if (readyFile.localPath != null && readyFile.localPath!.isNotEmpty) {
        final f = File(readyFile.localPath!);
        if (await f.exists() && await f.length() > 0) {
          needsDownload = false;
        }
      }

      if (needsDownload) {
        try {
          readyFile = await downloadFile(file);
        } catch (e) {
          debugPrint(
            '[MEDIA] Error downloading ${file.name} for bulk share: $e',
          );
          allSuccess = false;
          continue;
        }
      }

      if (readyFile.localPath != null) {
        final f = File(readyFile.localPath!);
        if (await f.exists() && await f.length() > 0) {
          readyPaths.add(readyFile.localPath!);
          readyMimes.add(
            NativeMediaService.resolveMimeType(
              fileName: readyFile.name,
              currentMime: readyFile.mimeType,
              isPhoto: readyFile.isPhoto,
              isVideo: readyFile.isVideo,
            ),
          );
        } else {
          allSuccess = false;
        }
      } else {
        allSuccess = false;
      }
    }

    if (isCancelled?.call() == true) {
      return false;
    }

    if (readyPaths.isEmpty) {
      exitSelectionMode();
      return false;
    }

    try {
      final allPhotos = targets.every((f) => f.isPhoto);
      final allVideos = targets.every((f) => f.isVideo);
      final categoryText = allPhotos
          ? 'photos'
          : (allVideos ? 'videos' : 'items');
      final title = readyPaths.length == 1
          ? targets.first.name
          : 'Share ${readyPaths.length} $categoryText';

      final shared = await NativeMediaService.shareFiles(
        filePaths: readyPaths,
        mimeTypes: readyMimes,
        title: title,
      );
      if (!shared) allSuccess = false;
    } catch (e) {
      debugPrint('[MEDIA] Error bulk sharing files: $e');
      allSuccess = false;
    }

    exitSelectionMode();
    return allSuccess;
  }

  /// Bulk moves selected files to the secure Locked Folder.
  /// Automatically exits selection mode upon completion.
  Future<int> moveSelectedToLockedFolder(Uint8List masterKey) async {
    final targets = selectedFiles;
    if (targets.isEmpty) {
      exitSelectionMode();
      return 0;
    }

    int count = 0;
    for (final file in targets) {
      try {
        await _lockedFolderController.repository.moveToLockedFolder(
          file: file,
          masterKey: masterKey,
        );
        _recentMedia.removeWhere(
          (f) => f.telegramMessageId == file.telegramMessageId,
        );
        count++;
      } catch (e) {
        debugPrint(
          '[MEDIA] Error moving #${file.telegramMessageId} to locked folder: $e',
        );
      }
    }

    try {
      _collectionCounts = await _repository.getCachedCollectionCounts();
    } catch (_) {}

    exitSelectionMode();
    notifyListeners();
    return count;
  }

  @override
  void dispose() {
    _uploadController.removeListener(_onUploadQueueChanged);
    _batchManager.dispose();
    super.dispose();
  }
}
