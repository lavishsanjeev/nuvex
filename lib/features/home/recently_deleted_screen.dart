import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/database/remote_file.dart';
import 'controllers/media_controller.dart';
import 'media_viewer_screen.dart';
import 'repositories/media_repository.dart';
import 'widgets/media_tile.dart';

/// Screen displaying items currently moved to Recently Deleted (Trash).
///
/// Implements Nuvex Trash requirements:
/// - Real trashed media only from SQLite database
/// - 4-column MediaTile gallery grid layout
/// - Real thumbnails loaded from app-private cache
/// - Trashed days-remaining badge on each tile
/// - Empty state when Trash is empty
/// - Single-item and bulk permanent delete operations
/// - Real-time synchronization with MediaController
class RecentlyDeletedScreen extends StatefulWidget {
  final MediaRepository? repository;
  final MediaController? mediaController;

  const RecentlyDeletedScreen({
    super.key,
    this.repository,
    this.mediaController,
  });

  @override
  State<RecentlyDeletedScreen> createState() => _RecentlyDeletedScreenState();
}

class _RecentlyDeletedScreenState extends State<RecentlyDeletedScreen> {
  late final MediaRepository _repository;
  late final MediaController _mediaController;
  List<RemoteFile> _items = [];
  bool _isLoading = true;
  bool _isEmptying = false;

  @override
  void initState() {
    super.initState();
    _repository =
        widget.repository ??
        widget.mediaController?.repository ??
        MediaRepository();
    _mediaController =
        widget.mediaController ?? MediaController(repository: _repository);
    _mediaController.addListener(_handleControllerUpdate);
    _loadTrashedFiles();
  }

  void _handleControllerUpdate() {
    if (!mounted) return;
    _loadTrashedFiles();
  }

  @override
  void dispose() {
    _mediaController.removeListener(_handleControllerUpdate);
    super.dispose();
  }

  Future<void> _loadTrashedFiles() async {
    try {
      final files = await _repository.getTrashedMedia();
      if (mounted) {
        setState(() {
          _items = files;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _confirmEmptyTrash() async {
    if (_isEmptying || _items.isEmpty) return;

    final shouldEmpty = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF18181B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Colors.white12),
        ),
        title: const Row(
          children: [
            Icon(
              Icons.delete_forever_rounded,
              color: Colors.redAccent,
              size: 24,
            ),
            SizedBox(width: 10),
            Text(
              'Empty Trash?',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: Colors.white,
              ),
            ),
          ],
        ),
        content: Text(
          'Permanently delete ${_items.length} ${_items.length == 1 ? 'item' : 'items'} from Telegram and your device? This cannot be undone.',
          style: const TextStyle(
            fontFamily: NuvexTypography.primaryFamily,
            fontSize: 14,
            color: Colors.white70,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                color: Colors.white60,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Empty Trash',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (shouldEmpty == true) {
      await _executeEmptyTrash();
    }
  }

  Future<void> _executeEmptyTrash() async {
    setState(() => _isEmptying = true);
    int failedCount = 0;

    final filesToDelete = List<RemoteFile>.from(_items);
    for (final file in filesToDelete) {
      try {
        await _mediaController.permanentlyDeleteMedia(file);
      } catch (e) {
        failedCount++;
        debugPrint(
          '[TRASH] Failed to permanently delete #${file.telegramMessageId}: $e',
        );
      }
    }

    if (mounted) {
      setState(() => _isEmptying = false);

      if (failedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not delete $failedCount items from Telegram. Kept in Trash.',
            ),
            backgroundColor: NuvexColors.errorRed,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Trash emptied successfully'),
            backgroundColor: Color(0xFF1E293B),
          ),
        );
      }

      await _loadTrashedFiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NuvexColors.iceBackground,
      appBar: AppBar(
        backgroundColor: NuvexColors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: NuvexColors.darkNavy,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recently Deleted',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: NuvexColors.darkNavy,
                letterSpacing: -0.4,
              ),
            ),
            if (!_isLoading && _items.isNotEmpty)
              Text(
                '${_items.length} ${_items.length == 1 ? 'item' : 'items'} • Auto-deletes in 30 days',
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 12,
                  color: NuvexColors.secondaryText,
                ),
              ),
          ],
        ),
        actions: [
          if (!_isLoading && _items.isNotEmpty)
            _isEmptying
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                  )
                : TextButton(
                    onPressed: _confirmEmptyTrash,
                    child: const Text(
                      'Empty',
                      style: TextStyle(
                        fontFamily: NuvexTypography.primaryFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: NuvexColors.primaryBlue,
                  ),
                ),
              )
            : _items.isEmpty
            ? _buildEmptyState()
            : _buildContent(),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: const BoxDecoration(
                color: Color(0xFFF1F5F9),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.delete_outline_rounded,
                size: 38,
                color: NuvexColors.secondaryText,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Trash is Empty',
              style: TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: NuvexColors.darkNavy,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Photos and videos you delete will stay here for 30 days before being permanently removed from Telegram.',
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

  Widget _buildContent() {
    final screenWidth = MediaQuery.of(context).size.width;
    final int crossAxisCount = screenWidth < 600
        ? 4
        : (screenWidth / 100).floor().clamp(4, 12);

    return Column(
      children: [
        // Informational header banner
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            color: Color(0xFFFEF2F2),
            border: Border(
              bottom: BorderSide(color: Color(0xFFFEE2E2), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.auto_delete_outlined,
                size: 18,
                color: Color(0xFFDC2626),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Items show days remaining before permanent deletion. Tap an item to restore or delete it permanently.',
                  style: TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 12,
                    color: Colors.red.shade900,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),

        // 4-Column GridView matching Photos and CollectionDetail
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.0),
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              physics: const BouncingScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 2.5,
                mainAxisSpacing: 2.5,
                childAspectRatio: 1.0,
              ),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final file = _items[index];
                return MediaTile(
                  file: file,
                  controller: _mediaController,
                  badgeText: '${file.daysRemainingInTrash}d',
                  onTap: () {
                    Navigator.of(context).push(
                      MediaViewerScreen.route(
                        files: _items,
                        initialIndex: index,
                        controller: _mediaController,
                        isTrashMode: true,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
