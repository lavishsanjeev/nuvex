import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/database/remote_file.dart';
import '../../home/controllers/media_controller.dart';
import '../../home/widgets/nuvex_loading_view.dart';
import '../controllers/locked_folder_controller.dart';
import 'change_pin_dialog.dart';
import 'locked_media_viewer_screen.dart';

/// Full-screen private Locked Folder for Nuvex.
///
/// Features:
/// - PIN setup, confirmation, and changing
/// - Android hardware fingerprint / biometrics authentication
/// - Auto-locking on backgrounding
/// - Decrypted in-memory private thumbnail grid
/// - Bulk restore to gallery & bulk deletion
/// - Documented recovery policy
class LockedFolderScreen extends StatefulWidget {
  final LockedFolderController controller;
  final MediaController? mediaController;

  const LockedFolderScreen({
    super.key,
    required this.controller,
    this.mediaController,
  });

  @override
  State<LockedFolderScreen> createState() => _LockedFolderScreenState();
}

class _LockedFolderScreenState extends State<LockedFolderScreen> {
  String _enteredPin = '';
  String _setupFirstPin = '';
  bool _isConfirmingPin = false;
  bool _enableBiometricsInSetup = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    widget.controller.initialize().then((_) {
      if (mounted && widget.controller.isSetup && !widget.controller.isUnlocked) {
        // Automatically prompt biometrics if enabled
        if (widget.controller.isBiometricsEnabled &&
            widget.controller.isBiometricsAvailable &&
            widget.controller.lockoutSeconds == 0) {
          widget.controller.unlockWithBiometrics();
        }
      }
    });
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onKeyPress(String digit) {
    if (_enteredPin.length < 6) {
      setState(() {
        _enteredPin += digit;
      });

      if (_enteredPin.length >= 4) {
        // If not in setup, try unlocking automatically when length is 4 or 6
        if (widget.controller.isSetup) {
          if (_enteredPin.length == 4 || _enteredPin.length == 6) {
            _attemptPinUnlock();
          }
        }
      }
    }
  }

  void _onDeletePress() {
    if (_enteredPin.isNotEmpty) {
      setState(() {
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
      });
    }
  }

  Future<void> _attemptPinUnlock() async {
    final pin = _enteredPin;
    final success = await widget.controller.unlockWithPin(pin);
    if (!success && mounted) {
      setState(() {
        _enteredPin = '';
      });
    }
  }

  void _onSetupNext() {
    if (_enteredPin.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN must be at least 4 digits')),
      );
      return;
    }

    if (!_isConfirmingPin) {
      setState(() {
        _setupFirstPin = _enteredPin;
        _enteredPin = '';
        _isConfirmingPin = true;
      });
    } else {
      if (_enteredPin != _setupFirstPin) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PINs do not match. Please try again.'),
            backgroundColor: NuvexColors.errorRed,
          ),
        );
        setState(() {
          _enteredPin = '';
          _setupFirstPin = '';
          _isConfirmingPin = false;
        });
        return;
      }

      widget.controller.setupPin(
        _enteredPin,
        enableBiometrics: _enableBiometricsInSetup,
      );
    }
  }

  void _showForgotPinDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.help_outline_rounded, color: NuvexColors.primaryBlue),
            SizedBox(width: 10),
            Text(
              'Forgot PIN?',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontWeight: FontWeight.w700,
                color: NuvexColors.darkNavy,
              ),
            ),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'For your security, Locked Folder uses zero-knowledge encryption. '
              'Biometrics and passwords cannot bypass a forgotten PIN.',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 14,
                color: NuvexColors.secondaryText,
                height: 1.4,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Your original photos and videos remain safely preserved in Telegram Saved Messages. '
              'If you permanently lose your PIN, you can reset the folder.',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 13,
                color: NuvexColors.secondaryText,
                height: 1.4,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleRestore() async {
    final count = widget.controller.selectedCount;
    if (count == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Restore to Gallery?'),
        content: Text(
          'Move $count ${count == 1 ? 'item' : 'items'} back to your normal photo library?',
        ),
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
      final restored = await widget.controller.restoreSelectedItems();
      final mediaController = widget.mediaController ?? MediaController();
      await mediaController.refreshAfterLockedFolderRestore(
        restoredFiles: restored,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Restored ${restored.length} ${restored.length == 1 ? 'item' : 'items'} to gallery',
            ),
          ),
        );
      }
    }
  }

  Future<void> _handleDelete() async {
    final count = widget.controller.selectedCount;
    if (count == 0) return;

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
        content: Text(
          'Permanently delete $count ${count == 1 ? 'item' : 'items'} from this device? This action cannot be undone.',
        ),
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
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final deleted = await widget.controller.deleteSelectedItems();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted $deleted ${deleted == 1 ? 'item' : 'items'}'),
            backgroundColor: NuvexColors.errorRed,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.isLoading && !widget.controller.isUnlocked) {
      return Scaffold(
        backgroundColor: NuvexColors.background,
        appBar: AppBar(
          title: const Text(
            'Locked Folder',
            style: TextStyle(
              fontFamily: NuvexTypography.primaryFamily,
              fontWeight: FontWeight.w700,
              fontSize: 18,
              color: NuvexColors.darkNavy,
            ),
          ),
          elevation: 0,
          backgroundColor: Colors.transparent,
          iconTheme: const IconThemeData(color: NuvexColors.darkNavy),
        ),
        body: const NuvexLoadingView.galleryGrid(),
      );
    }

    if (!widget.controller.isSetup) {
      return _buildSetupView();
    }

    if (!widget.controller.isUnlocked) {
      return _buildLockView();
    }

    return _buildUnlockedGallery();
  }

  // ── 1. Setup PIN View ──

  Widget _buildSetupView() {
    return Scaffold(
      backgroundColor: NuvexColors.background,
      appBar: AppBar(
        title: const Text('Set up Locked Folder'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 16),
              Container(
                width: 68,
                height: 68,
                decoration: const BoxDecoration(
                  color: Color(0xFFEFF6FF),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.lock_rounded,
                  size: 34,
                  color: NuvexColors.primaryBlue,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _isConfirmingPin ? 'Confirm your PIN' : 'Create a Folder PIN',
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: NuvexColors.darkNavy,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _isConfirmingPin
                    ? 'Re-enter your 4–6 digit PIN to verify.'
                    : 'Choose a 4–6 digit PIN to protect your private media.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  color: NuvexColors.secondaryText,
                ),
              ),
              const SizedBox(height: 28),

              // PIN Indicators
              _buildPinBullets(_enteredPin.length),

              if (widget.controller.isBiometricsAvailable && !_isConfirmingPin) ...[
                const SizedBox(height: 20),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Unlock with fingerprint / biometrics',
                    style: TextStyle(
                      fontFamily: NuvexTypography.primaryFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: NuvexColors.darkNavy,
                    ),
                  ),
                  value: _enableBiometricsInSetup,
                  activeThumbColor: NuvexColors.primaryBlue,
                  onChanged: (val) {
                    setState(() {
                      _enableBiometricsInSetup = val;
                    });
                  },
                ),
              ],

              const Spacer(),

              // Numeric keypad
              _buildKeypad(showBiometrics: false),
              const SizedBox(height: 16),

              ElevatedButton(
                onPressed: _enteredPin.length >= 4 ? _onSetupNext : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: NuvexColors.primaryBlue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  _isConfirmingPin ? 'Confirm PIN' : 'Next',
                  style: const TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ── 2. Locked PIN View ──

  Widget _buildLockView() {
    final lockoutSec = widget.controller.lockoutSeconds;
    final isLockedOut = lockoutSec > 0;

    return Scaffold(
      backgroundColor: NuvexColors.background,
      appBar: AppBar(
        title: const Text('Locked Folder'),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: Color(0xFFEFF6FF),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.lock_rounded,
                  size: 32,
                  color: NuvexColors.primaryBlue,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Enter PIN',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: NuvexColors.darkNavy,
                ),
              ),
              const SizedBox(height: 8),
              if (isLockedOut)
                Text(
                  'Too many attempts. Try again in $lockoutSec s.',
                  style: const TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: NuvexColors.errorRed,
                  ),
                )
              else if (widget.controller.errorMessage != null)
                Text(
                  widget.controller.errorMessage!,
                  style: const TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: NuvexColors.errorRed,
                  ),
                )
              else
                const Text(
                  'Enter your PIN or use biometrics to view protected media.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 14,
                    color: NuvexColors.secondaryText,
                  ),
                ),

              const SizedBox(height: 32),
              _buildPinBullets(_enteredPin.length),

              const Spacer(),

              // Keypad with biometrics button
              _buildKeypad(
                showBiometrics: widget.controller.isBiometricsEnabled &&
                    widget.controller.isBiometricsAvailable,
                onBiometricTap: () => widget.controller.unlockWithBiometrics(),
                disabled: isLockedOut,
              ),

              const SizedBox(height: 12),
              TextButton(
                onPressed: _showForgotPinDialog,
                child: const Text(
                  'Forgot PIN?',
                  style: TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    color: NuvexColors.primaryBlue,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPinBullets(int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (index) {
        final isFilled = index < count;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: isFilled ? NuvexColors.primaryBlue : const Color(0xFFE2E8F0),
            shape: BoxShape.circle,
            border: Border.all(
              color: isFilled ? NuvexColors.primaryBlue : const Color(0xFFCBD5E1),
              width: 1.5,
            ),
          ),
        );
      }),
    );
  }

  Widget _buildKeypad({
    required bool showBiometrics,
    VoidCallback? onBiometricTap,
    bool disabled = false,
  }) {
    return Column(
      children: [
        _buildKeypadRow(['1', '2', '3'], disabled: disabled),
        const SizedBox(height: 14),
        _buildKeypadRow(['4', '5', '6'], disabled: disabled),
        const SizedBox(height: 14),
        _buildKeypadRow(['7', '8', '9'], disabled: disabled),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Left action (Biometrics or empty)
            if (showBiometrics)
              _buildKeypadButton(
                child: const Icon(
                  Icons.fingerprint_rounded,
                  size: 28,
                  color: NuvexColors.primaryBlue,
                ),
                onTap: disabled ? null : onBiometricTap,
              )
            else
              const SizedBox(width: 72, height: 72),

            _buildKeypadButton(
              child: const Text(
                '0',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: NuvexColors.darkNavy,
                ),
              ),
              onTap: disabled ? null : () => _onKeyPress('0'),
            ),

            _buildKeypadButton(
              child: const Icon(
                Icons.backspace_outlined,
                size: 22,
                color: NuvexColors.darkNavy,
              ),
              onTap: disabled ? null : _onDeletePress,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildKeypadRow(List<String> digits, {bool disabled = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits.map((d) {
        return _buildKeypadButton(
          child: Text(
            d,
            style: const TextStyle(
              fontFamily: NuvexTypography.primaryFamily,
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: NuvexColors.darkNavy,
            ),
          ),
          onTap: disabled ? null : () => _onKeyPress(d),
        );
      }).toList(),
    );
  }

  Widget _buildKeypadButton({required Widget child, VoidCallback? onTap}) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Material(
        color: const Color(0xFFF8FAFC),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    );
  }

  void _openMediaViewer(int index) {
    if (!widget.controller.isUnlocked || widget.controller.masterKey == null) return;
    if (index < 0 || index >= widget.controller.lockedFiles.length) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LockedMediaViewerScreen(
          files: widget.controller.lockedFiles,
          initialIndex: index,
          controller: widget.controller,
          mediaController: widget.mediaController ?? MediaController(),
        ),
      ),
    );
  }

  // ── 3. Unlocked Private Gallery View ──

  Widget _buildUnlockedGallery() {
    if (widget.controller.isLoading) {
      return Scaffold(
        backgroundColor: NuvexColors.background,
        appBar: AppBar(
          title: const Row(
            children: [
              Icon(Icons.lock_open_rounded, size: 20, color: NuvexColors.primaryBlue),
              SizedBox(width: 8),
              Text('Locked Folder'),
            ],
          ),
          elevation: 0,
          backgroundColor: Colors.white,
          iconTheme: const IconThemeData(color: NuvexColors.darkNavy),
        ),
        body: const NuvexLoadingView.galleryGrid(),
      );
    }

    if (widget.controller.errorMessage != null && widget.controller.lockedFiles.isEmpty) {
      return Scaffold(
        backgroundColor: NuvexColors.background,
        appBar: AppBar(
          title: const Text('Locked Folder'),
          elevation: 0,
          backgroundColor: Colors.white,
          iconTheme: const IconThemeData(color: NuvexColors.darkNavy),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, size: 48, color: NuvexColors.errorRed),
                const SizedBox(height: 16),
                Text(
                  widget.controller.errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: NuvexColors.darkNavy,
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => widget.controller.reload(),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NuvexColors.primaryBlue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final files = widget.controller.lockedFiles;
    final isSelection = widget.controller.isSelectionMode;

    return Scaffold(
      backgroundColor: NuvexColors.background,
      appBar: AppBar(
        title: isSelection
            ? Text('${widget.controller.selectedCount} selected')
            : const Row(
                children: [
                  Icon(Icons.lock_open_rounded, size: 20, color: NuvexColors.primaryBlue),
                  SizedBox(width: 8),
                  Text('Locked Folder'),
                ],
              ),
        elevation: 0,
        backgroundColor: Colors.white,
        actions: [
          if (isSelection) ...[
            IconButton(
              icon: const Icon(Icons.select_all_rounded),
              tooltip: 'Select All',
              onPressed: () => widget.controller.selectAll(),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Cancel',
              onPressed: () => widget.controller.clearSelection(),
            ),
          ] else ...[
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (val) {
                if (val == 'change_pin') {
                  showDialog<void>(
                    context: context,
                    builder: (_) => ChangePinDialog(controller: widget.controller),
                  );
                } else if (val == 'biometrics') {
                  widget.controller.setBiometricsEnabled(
                    !widget.controller.isBiometricsEnabled,
                  );
                } else if (val == 'lock_now') {
                  widget.controller.lock();
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'change_pin',
                  child: Text('Change PIN'),
                ),
                if (widget.controller.isBiometricsAvailable)
                  PopupMenuItem(
                    value: 'biometrics',
                    child: Text(
                      widget.controller.isBiometricsEnabled
                          ? 'Disable Biometrics'
                          : 'Enable Biometrics',
                    ),
                  ),
                const PopupMenuItem(
                  value: 'lock_now',
                  child: Row(
                    children: [
                      Icon(Icons.lock_rounded, size: 18, color: NuvexColors.primaryBlue),
                      SizedBox(width: 8),
                      Text('Lock Now'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      body: files.isEmpty
          ? _buildEmptyState()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 2.5,
                  mainAxisSpacing: 2.5,
                  childAspectRatio: 1.0,
                ),
                itemCount: files.length,
                itemBuilder: (context, index) {
                  final file = files[index];
                  final isSelected = widget.controller.isFileSelected(file.telegramMessageId);

                  return _LockedTile(
                    file: file,
                    controller: widget.controller,
                    isSelected: isSelected,
                    isSelectionMode: isSelection,
                    onTap: () {
                      if (isSelection) {
                        widget.controller.toggleSelection(file);
                      } else {
                        _openMediaViewer(index);
                      }
                    },
                    onLongPress: () {
                      if (!isSelection) {
                        widget.controller.enterSelectionMode(file);
                      } else {
                        widget.controller.toggleSelection(file);
                      }
                    },
                  );
                },
              ),
            ),
      bottomNavigationBar: isSelection ? _buildSelectionBottomBar() : null,
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: Color(0xFFEFF6FF),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_outline_rounded,
                size: 36,
                color: NuvexColors.primaryBlue,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No locked media',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: NuvexColors.darkNavy,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Photos and videos you move here are encrypted and hidden from your normal gallery.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 14,
                color: NuvexColors.secondaryText,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBottomBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: ElevatedButton.icon(
                onPressed: _handleRestore,
                icon: const Icon(Icons.lock_open_rounded, size: 18),
                label: const Text(
                  'Restore to Gallery',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NuvexColors.primaryBlue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed: _handleDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 18, color: NuvexColors.errorRed),
                label: const Text(
                  'Delete',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: NuvexColors.errorRed),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFFCA5A5)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Decrypted in-memory tile for the Locked Folder private grid.
class _LockedTile extends StatelessWidget {
  final RemoteFile file;
  final LockedFolderController controller;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _LockedTile({
    required this.file,
    required this.controller,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.0,
      child: Material(
        color: const Color(0xFF1E293B),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Decrypted in-memory thumbnail
              FutureBuilder<Uint8List?>(
                future: controller.getThumbnailBytes(file),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    return Image.memory(
                      snapshot.data!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _buildFallbackIcon(),
                    );
                  }
                  return _buildFallbackIcon();
                },
              ),

              if (file.isVideo)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),

              // Selection overlay
              if (isSelected)
                Container(
                  color: NuvexColors.primaryBlue.withValues(alpha: 0.35),
                  child: const Center(
                    child: Icon(Icons.check_circle_rounded, color: Colors.white, size: 28),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFallbackIcon() {
    return Center(
      child: Icon(
        file.isVideo ? Icons.videocam_outlined : Icons.image_outlined,
        color: const Color(0xFF64748B),
        size: 28,
      ),
    );
  }
}
