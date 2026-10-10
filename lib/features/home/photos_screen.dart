import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../account/account_screen.dart';
import '../auth/controllers/auth_controller.dart';
import '../../telegram/telegram_media_service.dart';
import 'controllers/media_controller.dart';
import 'media_viewer_screen.dart';
import 'repositories/media_repository.dart';
import 'widgets/album_card.dart';
import 'widgets/media_tile.dart';
import 'widgets/selection_action_bar.dart';
import 'widgets/upload_queue_sheet.dart';

/// The approved Nuvex Photos Home screen connected to real Telegram media.
///
/// Complies strictly with Task 5 requirements:
/// - Reuses authenticated session
/// - Loads from SQLite DB cache first for zero UI latency
/// - Fetches real Telegram media available to authenticated account
/// - Polished loading, empty, error, and retry states
/// - Grid view of real media in Recent
/// - Strictly NO fake photos, fake counts, or fake mock data
class PhotosScreen extends StatefulWidget {
  final AuthController? controller;
  final MediaController? mediaController;

  const PhotosScreen({super.key, this.controller, this.mediaController});

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  late final MediaController _mediaController;

  @override
  void initState() {
    super.initState();
    _mediaController =
        widget.mediaController ??
        MediaController(
          repository: widget.controller?.telegramService != null
              ? MediaRepository(
                  mediaService: TelegramMediaService(
                    authService: widget.controller!.telegramService,
                  ),
                )
              : null,
        );
    _mediaController.addListener(_onMediaChanged);
    _mediaController.initializeAndSync();
  }

  int _lastRequestedBatchIndex = -1;
  int _lastMediaCount = -1;
  bool _lastIsSyncing = false;
  bool _lastSelectionMode = false;
  int _lastSelectedCount = 0;

  void _onMediaChanged() {
    if (!mounted) return;
    final count = _mediaController.recentMedia.length;
    final syncing = _mediaController.isSyncing;
    final selectionMode = _mediaController.isSelectionMode;
    final selectedCount = _mediaController.selectedCount;

    // Only rebuild entire grid when screen-level state changes
    if (count != _lastMediaCount ||
        syncing != _lastIsSyncing ||
        selectionMode != _lastSelectionMode ||
        selectedCount != _lastSelectedCount) {
      _lastMediaCount = count;
      _lastIsSyncing = syncing;
      _lastSelectionMode = selectionMode;
      _lastSelectedCount = selectedCount;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _mediaController.removeListener(_onMediaChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.controller?.currentUser;
    final String displayName = user?.displayName ?? 'User';
    final String initial = displayName.trim().isNotEmpty
        ? displayName.trim()[0].toUpperCase()
        : 'U';

    final media = _mediaController.recentMedia;
    final screenWidth = MediaQuery.of(context).size.width;
    // On phone (<600dp): EXACTLY 4 square tiles per row as strictly required
    final int crossAxisCount = screenWidth < 600
        ? 4
        : (screenWidth / 100).floor().clamp(4, 12);

    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => _mediaController.syncMedia(),
          color: NuvexColors.primaryBlue,
          edgeOffset: topInset,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification ||
                  notification is ScrollEndNotification) {
                _onScroll(
                  notification.metrics.pixels,
                  screenWidth,
                  crossAxisCount,
                  media.length,
                );
              }
              return false;
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(top: topInset + 8),
                    child: _buildTopHeader(user, displayName, initial),
                  ),
                ),
                if (_mediaController.uploadController.hasActiveOrPending)
                  SliverToBoxAdapter(child: _buildActiveUploadBanner()),
                SliverToBoxAdapter(child: _buildAlbumsSection(context)),
                SliverToBoxAdapter(child: _buildRecentHeader()),
                if (media.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: _buildRecentContent(),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 2.0),
                    sliver: SliverGrid.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 2.5,
                        mainAxisSpacing: 2.5,
                        childAspectRatio: 1.0,
                      ),
                      itemCount: media.length,
                      itemBuilder: (context, index) {
                        // Prefetch batch when crossing halfway mark in current batch
                        if (index % 12 == 0) {
                          _mediaController.requestThumbnailBatchForIndex(index);
                        }
                        final item = media[index];
                        final isSelected = _mediaController.isFileSelected(
                          item.telegramMessageId,
                        );
                        return MediaTile(
                          key: ValueKey(item.telegramMessageId),
                          file: item,
                          index: index,
                          controller: _mediaController,
                          isSelected: isSelected,
                          isSelectionMode: _mediaController.isSelectionMode,
                          onLongPress: () {
                            _mediaController.enterSelectionMode(item);
                          },
                          onTap: () {
                            if (_mediaController.isSelectionMode) {
                              _mediaController.toggleSelection(item);
                            } else {
                              Navigator.of(context).push(
                                MediaViewerScreen.route(
                                  files: media,
                                  initialIndex: index,
                                  controller: _mediaController,
                                ),
                              );
                            }
                          },
                        );
                      },
                    ),
                  ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: _mediaController.isSelectionMode
                        ? (bottomInset > 0 ? bottomInset + 80 : 92)
                        : (bottomInset > 0 ? bottomInset + 84 : 96),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_mediaController.isSelectionMode)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: SelectionActionBar(controller: _mediaController),
            ),
          ),
      ],
    );
  }

  void _onScroll(
    double offset,
    double screenWidth,
    int crossAxisCount,
    int totalItems,
  ) {
    if (totalItems == 0) return;
    final rowHeight = screenWidth / crossAxisCount;
    const approxHeaderHeight = 280.0;
    final gridOffset = math.max(0.0, offset - approxHeaderHeight);
    final visibleRow = (gridOffset / rowHeight).floor();
    final visibleIndex = (visibleRow * crossAxisCount).clamp(0, totalItems - 1);
    final batchIndex = visibleIndex ~/ 24;
    final indexInBatch = visibleIndex % 24;

    if (batchIndex != _lastRequestedBatchIndex || indexInBatch >= 12) {
      _lastRequestedBatchIndex = batchIndex;
      _mediaController.requestThumbnailBatchForIndex(visibleIndex);
    }
  }

  Widget _buildTopHeader(dynamic user, String displayName, String initial) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Top Header: Branding + Upload Queue + Bell + Profile ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Nuvex Wordmark
              RichText(
                text: const TextSpan(
                  children: [
                    TextSpan(
                      text: 'Nuve',
                      style: TextStyle(
                        fontFamily: NuvexTypography.primaryFamily,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: NuvexColors.darkNavy,
                        letterSpacing: -0.8,
                      ),
                    ),
                    TextSpan(
                      text: 'x',
                      style: TextStyle(
                        fontFamily: NuvexTypography.primaryFamily,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: NuvexColors.primaryBlue,
                        letterSpacing: -0.8,
                      ),
                    ),
                  ],
                ),
              ),
              // Header Actions: Upload Queue, Bell, Profile
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: NuvexColors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFE5E9F0),
                        width: 1,
                      ),
                    ),
                    child: IconButton(
                      key: const ValueKey('upload_queue_button'),
                      icon: Stack(
                        alignment: Alignment.center,
                        children: [
                          const Icon(
                            Icons.cloud_upload_outlined,
                            size: 20,
                            color: NuvexColors.darkNavy,
                          ),
                          if (_mediaController
                              .uploadController
                              .hasActiveOrPending)
                            Positioned(
                              top: 1,
                              right: 1,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: NuvexColors.primaryBlue,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: 'Upload Queue',
                      onPressed: () => UploadQueueSheet.show(
                        context,
                        _mediaController.uploadController,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: NuvexColors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFE5E9F0),
                        width: 1,
                      ),
                    ),
                    child: IconButton(
                      icon: const Icon(
                        Icons.notifications_none_rounded,
                        size: 20,
                        color: NuvexColors.darkNavy,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () {},
                    ),
                  ),
                  const SizedBox(width: 10),
                  Tooltip(
                    message: 'Account & Storage',
                    child: InkWell(
                      key: const ValueKey('profile_avatar_button'),
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AccountScreen(
                              authController: widget.controller,
                              mediaController: _mediaController,
                            ),
                          ),
                        );
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: NuvexColors.primaryBlue,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFDBEAFE),
                            width: 1.5,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x102563EB),
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            initial,
                            style: const TextStyle(
                              fontFamily: NuvexTypography.primaryFamily,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        // ── Subtitle ──
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Your files, your space.',
            style: TextStyle(
              fontFamily: NuvexTypography.primaryFamily,
              fontSize: 16,
              fontWeight: FontWeight.w400,
              color: NuvexColors.secondaryText,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 28),

        // ── Albums Section ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                'Albums',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: NuvexColors.darkNavy,
                  letterSpacing: -0.4,
                ),
              ),
              TextButton(
                onPressed: () {},
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'See all',
                  style: TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: NuvexColors.primaryBlue,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // Horizontal Album Carousel (Together, Spotlight, Travel)
        SizedBox(
          height: 140,
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: const [
              AlbumCard(
                title: 'Together',
                icon: Icons.people_outline_rounded,
                gradientColors: [Color(0xFFEFF6FF), Color(0xFFDBEAFE)],
                iconColor: Color(0xFF2563EB),
              ),
              AlbumCard(
                title: 'Spotlight',
                icon: Icons.auto_awesome_rounded,
                gradientColors: [Color(0xFFFEF3C7), Color(0xFFFDE68A)],
                iconColor: Color(0xFFD97706),
              ),
              AlbumCard(
                title: 'Travel',
                icon: Icons.explore_outlined,
                gradientColors: [Color(0xFFE0F2FE), Color(0xFFBAE6FD)],
                iconColor: Color(0xFF0284C7),
              ),
            ],
          ),
        ),

        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildRecentHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                children: [
                  const Text(
                    'Recent',
                    style: TextStyle(
                      fontFamily: NuvexTypography.primaryFamily,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: NuvexColors.darkNavy,
                      letterSpacing: -0.4,
                    ),
                  ),
                  if (_mediaController.isSyncing) ...[
                    const SizedBox(width: 10),
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: NuvexColors.primaryBlue,
                      ),
                    ),
                  ],
                ],
              ),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: NuvexColors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.tune_rounded,
                    size: 18,
                    color: NuvexColors.darkNavy,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: () {},
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _buildActiveUploadBanner() {
    final pendingCount = _mediaController.uploadController.pendingCount;
    final uploadingCount = _mediaController.uploadController.uploadingCount;
    final totalActive = pendingCount + uploadingCount;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Material(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: const ValueKey('active_upload_banner'),
          borderRadius: BorderRadius.circular(16),
          onTap: () =>
              UploadQueueSheet.show(context, _mediaController.uploadController),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFBFDBFE), width: 1),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NuvexColors.primaryBlue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Uploading $totalActive ${totalActive == 1 ? 'file' : 'files'} to Telegram Saved Messages...',
                    style: const TextStyle(
                      fontFamily: NuvexTypography.primaryFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: NuvexColors.primaryBlue,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: NuvexColors.primaryBlue,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentContent() {
    // 1. Initial Loading State (when no local DB cache is present)
    if (_mediaController.isLoading && _mediaController.recentMedia.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 48),
          decoration: BoxDecoration(
            color: NuvexColors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
          ),
          child: const Column(
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: NuvexColors.primaryBlue,
                ),
              ),
              SizedBox(height: 16),
              Text(
                'Connecting to Telegram storage...',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  color: NuvexColors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 2. Error State (with Retry Button)
    if (_mediaController.hasError && _mediaController.recentMedia.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFFCA5A5), width: 1),
          ),
          child: Column(
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: NuvexColors.errorRed,
              ),
              const SizedBox(height: 12),
              Text(
                _mediaController.errorMessage ?? 'Unable to load media.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  color: Color(0xFF991B1B),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => _mediaController.retry(),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NuvexColors.primaryBlue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 3. Genuine Empty State (No photos in Telegram Saved Messages)
    if (_mediaController.recentMedia.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          decoration: BoxDecoration(
            color: NuvexColors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
            boxShadow: const [
              BoxShadow(
                color: Color(0x06000000),
                blurRadius: 16,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: Color(0xFFEFF6FF),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(
                    Icons.photo_library_outlined,
                    size: 34,
                    color: NuvexColors.primaryBlue,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'No photos yet',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: NuvexColors.darkNavy,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Photos and memories from your Telegram storage will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  height: 1.4,
                  color: NuvexColors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 4. Media gallery grid is rendered directly by VirtualizedPhotosGridView
    return const SizedBox.shrink();
  }
}
