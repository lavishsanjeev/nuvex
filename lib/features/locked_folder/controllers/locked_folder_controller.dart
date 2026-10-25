// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/database/remote_file.dart';
import '../repositories/locked_folder_repository.dart';
import '../services/locked_folder_auth_service.dart';

/// Controller coordinating Locked Folder authentication, auto-lock lifecycle,
/// encrypted item management, and private in-memory decryption.
class LockedFolderController extends ChangeNotifier with WidgetsBindingObserver {
  final LockedFolderAuthService _authService;
  final LockedFolderRepository _repository;

  bool _isUnlocked = false;
  bool _isSetup = false;
  bool _isBiometricsAvailable = false;
  bool _isBiometricsEnabled = false;
  bool _isLoading = false;
  String? _errorMessage;
  int _lockoutSeconds = 0;
  Timer? _lockoutTimer;

  Uint8List? _masterKey;
  List<RemoteFile> _lockedFiles = [];

  // Multi-selection within locked folder
  final Set<int> _selectedIds = {};

  LockedFolderController({
    required LockedFolderAuthService authService,
    required LockedFolderRepository repository,
  })  : _authService = authService,
        _repository = repository {
    WidgetsBinding.instance.addObserver(this);
  }

  LockedFolderRepository get repository => _repository;

  bool get isUnlocked => _isUnlocked;
  bool get isSetup => _isSetup;
  bool get isBiometricsAvailable => _isBiometricsAvailable;
  bool get isBiometricsEnabled => _isBiometricsEnabled;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  int get lockoutSeconds => _lockoutSeconds;
  List<RemoteFile> get lockedFiles => List.unmodifiable(_lockedFiles);
  Uint8List? get masterKey => _masterKey;

  // Selection
  bool _isExplicitSelectionMode = false;
  bool get isSelectionMode => _isExplicitSelectionMode || _selectedIds.isNotEmpty;
  int get selectedCount => _selectedIds.length;
  bool isFileSelected(int id) => _selectedIds.contains(id);
  List<RemoteFile> get selectedFiles =>
      _lockedFiles.where((f) => _selectedIds.contains(f.telegramMessageId)).toList();

  void enterSelectionMode(RemoteFile initialFile) {
    _isExplicitSelectionMode = true;
    _selectedIds.clear();
    _selectedIds.add(initialFile.telegramMessageId);
    notifyListeners();
  }

  void exitSelectionMode() {
    _isExplicitSelectionMode = false;
    _selectedIds.clear();
    notifyListeners();
  }

  void toggleSelection(RemoteFile file) {
    if (_selectedIds.contains(file.telegramMessageId)) {
      _selectedIds.remove(file.telegramMessageId);
      if (_selectedIds.isEmpty) {
        _isExplicitSelectionMode = false;
      }
    } else {
      _selectedIds.add(file.telegramMessageId);
    }
    notifyListeners();
  }

  void selectAll() {
    _isExplicitSelectionMode = true;
    _selectedIds.addAll(_lockedFiles.map((f) => f.telegramMessageId));
    notifyListeners();
  }

  void deselectAll() {
    _isExplicitSelectionMode = false;
    _selectedIds.clear();
    notifyListeners();
  }

  void clearSelection() {
    _isExplicitSelectionMode = false;
    _selectedIds.clear();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Lock automatically when the app is backgrounded or loses active focus
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (_isUnlocked) {
        debugPrint('[LOCKED_FOLDER] App backgrounded: auto-locking protected folder');
        lock();
      }
    }
  }

  /// Initializes setup state, biometrics availability, and attempt throttling.
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      _isSetup = await _authService.isSetupComplete();
      _isBiometricsAvailable = await _authService.isBiometricsAvailable();
      _isBiometricsEnabled = await _authService.isBiometricsEnabled();
      _lockoutSeconds = await _authService.getRemainingLockoutSeconds();

      if (_lockoutSeconds > 0) {
        _startLockoutCountdown();
      }
    } catch (e) {
      debugPrint('[LOCKED_FOLDER] Init error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Configures PIN for the first time.
  Future<void> setupPin(String pin, {bool enableBiometrics = true}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _authService.setupPin(pin, enableBiometrics: enableBiometrics);
      _isSetup = true;
      _isBiometricsEnabled = enableBiometrics;
      // Auto-unlock upon successful initial configuration
      _masterKey = await _authService.getMasterKey();
      _isUnlocked = true;
      await _loadLockedFiles();
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Unlocks the folder using PIN.
  Future<bool> unlockWithPin(String pin) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final success = await _authService.verifyPin(pin);
      if (success) {
        _masterKey = await _authService.getMasterKey();
        _isUnlocked = true;
        _errorMessage = null;
        await _loadLockedFiles();
        return true;
      } else {
        _errorMessage = 'Incorrect PIN';
        _lockoutSeconds = await _authService.getRemainingLockoutSeconds();
        if (_lockoutSeconds > 0) {
          _startLockoutCountdown();
        }
        return false;
      }
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      _lockoutSeconds = await _authService.getRemainingLockoutSeconds();
      if (_lockoutSeconds > 0) {
        _startLockoutCountdown();
      }
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Unlocks using Android hardware biometrics (fingerprint/face).
  Future<bool> unlockWithBiometrics() async {
    if (_lockoutSeconds > 0) {
      _errorMessage = 'Locked out. Please wait $_lockoutSeconds seconds.';
      notifyListeners();
      return false;
    }

    _errorMessage = null;
    try {
      final success = await _authService.authenticateWithBiometrics();
      if (success) {
        _masterKey = await _authService.getMasterKey();
        _isUnlocked = true;
        _errorMessage = null;
        await _loadLockedFiles();
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      _errorMessage = 'Biometric authentication failed';
      notifyListeners();
      return false;
    }
  }

  /// Changes the PIN.
  Future<void> changePin({
    required String oldPin,
    required String newPin,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _authService.changePin(oldPin: oldPin, newPin: newPin);
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Toggles biometric unlock.
  Future<void> setBiometricsEnabled(bool enabled) async {
    await _authService.setBiometricsEnabled(enabled);
    _isBiometricsEnabled = enabled;
    notifyListeners();
  }

  /// Locks the folder immediately, clearing the master key and in-memory caches.
  void lock() {
    _isUnlocked = false;
    _masterKey = null;
    _selectedIds.clear();
    _lockedFiles = [];
    notifyListeners();
  }

  /// Moves selected gallery items into the Locked Folder.
  Future<int> moveItemsToLockedFolder(List<RemoteFile> files) async {
    if (!_isSetup) {
      throw StateError('Locked Folder PIN must be set up before locking files');
    }
    final key = _masterKey ?? await _authService.getMasterKey();

    int movedCount = 0;
    for (final file in files) {
      await _repository.moveToLockedFolder(file: file, masterKey: key);
      movedCount++;
    }

    if (_isUnlocked) {
      await _loadLockedFiles();
    }
    notifyListeners();
    return movedCount;
  }

  /// Restores selected items from the Locked Folder back to the normal gallery.
  /// Returns the list of restored [RemoteFile] instances.
  Future<List<RemoteFile>> restoreSelectedItems() async {
    if (!_isUnlocked || _masterKey == null) {
      throw StateError('Locked Folder is not unlocked');
    }

    final targets = selectedFiles;
    if (targets.isEmpty) return [];

    final List<RemoteFile> restored = [];
    final List<int> successfullyRestoredIds = [];

    for (final file in targets) {
      try {
        final restoredFile = await _repository.restoreFromLockedFolder(
          file: file,
          masterKey: _masterKey!,
        );
        restored.add(restoredFile);
        successfullyRestoredIds.add(file.telegramMessageId);
      } catch (e) {
        debugPrint('[LOCKED_CONTROLLER] Error restoring file #${file.telegramMessageId}: $e');
      }
    }

    // Only clear successfully restored items from selection
    _selectedIds.removeWhere((id) => successfullyRestoredIds.contains(id));
    if (_selectedIds.isEmpty) {
      _isExplicitSelectionMode = false;
    }

    // Immediately remove successfully restored items from in-memory collection
    _lockedFiles = _lockedFiles
        .where((f) => !successfullyRestoredIds.contains(f.telegramMessageId))
        .toList();

    // Reload from database to ensure metadata and collection counts are consistent
    await _loadLockedFiles();
    notifyListeners();
    return restored;
  }

  /// Restores a single file back to the normal gallery.
  Future<RemoteFile> restoreSingleFile(RemoteFile file) async {
    if (!_isUnlocked || _masterKey == null) {
      throw StateError('Locked Folder is not unlocked');
    }
    final restored = await _repository.restoreFromLockedFolder(
      file: file,
      masterKey: _masterKey!,
    );
    _selectedIds.remove(file.telegramMessageId);
    if (_selectedIds.isEmpty) {
      _isExplicitSelectionMode = false;
    }
    _lockedFiles = _lockedFiles
        .where((f) => f.telegramMessageId != file.telegramMessageId)
        .toList();
    await _loadLockedFiles();
    notifyListeners();
    return restored;
  }

  /// Reloads the locked media list from the database.
  Future<void> reload() async {
    if (_isUnlocked) {
      await _loadLockedFiles();
    }
  }

  /// Decrypts full media bytes in memory (e.g. for private photo viewing).
  Future<Uint8List?> getMediaBytes(RemoteFile file) async {
    if (!_isUnlocked || _masterKey == null) return null;
    try {
      return await _repository.getDecryptedMediaBytes(
        file: file,
        masterKey: _masterKey!,
      );
    } catch (e) {
      debugPrint('[LOCKED_CONTROLLER] Error decrypting media bytes: $e');
      return null;
    }
  }

  /// Safely decrypts temporary video file for playback.
  Future<File?> getTempVideoFile(RemoteFile file) async {
    if (!_isUnlocked || _masterKey == null) return null;
    try {
      return await _repository.getDecryptedTempVideoFile(
        file: file,
        masterKey: _masterKey!,
      );
    } catch (e) {
      debugPrint('[LOCKED_CONTROLLER] Error decrypting temp video: $e');
      return null;
    }
  }

  /// Permanently deletes selected items from the Locked Folder.
  Future<int> deleteSelectedItems() async {
    final targets = selectedFiles;
    if (targets.isEmpty) return 0;

    int deletedCount = 0;
    for (final file in targets) {
      await _repository.deleteLockedFile(file);
      deletedCount++;
    }

    _selectedIds.clear();
    await _loadLockedFiles();
    notifyListeners();
    return deletedCount;
  }

  /// Decrypts thumbnail bytes for in-memory rendering.
  Future<Uint8List?> getThumbnailBytes(RemoteFile file) async {
    if (!_isUnlocked || _masterKey == null) return null;
    return _repository.getDecryptedThumbnailBytes(
      file: file,
      masterKey: _masterKey!,
    );
  }

  Future<void> _loadLockedFiles() async {
    _lockedFiles = await _repository.getLockedFiles();
  }

  void _startLockoutCountdown() {
    _lockoutTimer?.cancel();
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_lockoutSeconds > 0) {
        _lockoutSeconds--;
        notifyListeners();
      } else {
        timer.cancel();
        _lockoutTimer = null;
        _errorMessage = null;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockoutTimer?.cancel();
    _masterKey = null;
    super.dispose();
  }
}
