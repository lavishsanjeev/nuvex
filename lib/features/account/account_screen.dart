import 'dart:math';

import 'package:flutter/material.dart';

import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/database/nuvex_database.dart';
import '../../core/services/storage_cache_manager.dart';
import '../auth/controllers/auth_controller.dart';
import '../home/collection_detail_screen.dart';
import '../home/controllers/media_controller.dart';

/// Clean utility to format byte counts into human-readable strings.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = (log(bytes) / log(1024)).floor();
  if (i >= suffixes.length) i = suffixes.length - 1;
  final num = bytes / pow(1024, i);
  return '${num.toStringAsFixed(num < 10 && i > 0 ? 1 : 0)} ${suffixes[i]}';
}

/// Comprehensive Account, Storage, and Cache management screen in Nuvex.
///
/// Features:
/// 1. Profile Header with Telegram account data & refresh
/// 2. Google Photos-style Storage Card with real SQLite metadata calculations
/// 3. Filtered storage drill-downs (Photos, Videos, Documents, Largest files)
/// 4. Synchronized media status & manual sync trigger
/// 5. Local on-disk cache management (thumbnails, video chunks, full media)
/// 6. Safe session logout without touching Telegram cloud files
/// 7. App settings & system info
class AccountScreen extends StatefulWidget {
  final AuthController? authController;
  final MediaController? mediaController;
  final StorageCacheManager? cacheManager;

  const AccountScreen({
    super.key,
    this.authController,
    this.mediaController,
    this.cacheManager,
  });

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late final AuthController _authController;
  late final MediaController _mediaController;
  late final StorageCacheManager _cacheManager;

  NuvexStorageStats _storageStats = NuvexStorageStats.empty;
  NuvexCacheInfo _cacheInfo = NuvexCacheInfo.empty;
  bool _isLoadingStats = true;
  bool _isRefreshingProfile = false;

  // Settings state (in-memory toggles with instant response)
  bool _autoSync = true;
  bool _wifiOnly = false;
  bool _notifications = true;

  @override
  void initState() {
    super.initState();
    _authController = widget.authController ?? AuthController();
    _mediaController = widget.mediaController ?? MediaController();
    _cacheManager = widget.cacheManager ?? StorageCacheManager();

    _mediaController.addListener(_onMediaControllerChanged);
    _authController.addListener(_onAuthControllerChanged);

    _loadAllStats();
  }

  @override
  void dispose() {
    _mediaController.removeListener(_onMediaControllerChanged);
    _authController.removeListener(_onAuthControllerChanged);
    super.dispose();
  }

  void _onMediaControllerChanged() {
    if (mounted) {
      setState(() {});
      _loadAllStats();
    }
  }

  void _onAuthControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadAllStats() async {
    try {
      final repo = _mediaController.repository;
      final statsFuture = repo.getStorageStats();
      final cacheFuture = _cacheManager.calculateCacheSizes();

      final results = await Future.wait([statsFuture, cacheFuture]);
      if (mounted) {
        setState(() {
          _storageStats = results[0] as NuvexStorageStats;
          _cacheInfo = results[1] as NuvexCacheInfo;
          _isLoadingStats = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingStats = false);
      }
    }
  }

  Future<void> _refreshAccountInfo() async {
    setState(() => _isRefreshingProfile = true);
    final success = await _authController.refreshCurrentUser();
    if (mounted) {
      setState(() => _isRefreshingProfile = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Account info refreshed from Telegram.'
                : 'Could not refresh account info.',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _handleSyncNow() async {
    if (_mediaController.isSyncing) return;
    try {
      await _mediaController.syncMedia();
      await _loadAllStats();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sync completed successfully.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _clearThumbnailCache() async {
    await _cacheManager.clearThumbnailCache();
    await _loadAllStats();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thumbnail cache cleared (cloud media preserved).'),
        ),
      );
    }
  }

  Future<void> _clearVideoCache() async {
    await _cacheManager.clearVideoCache();
    await _loadAllStats();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video stream cache cleared (cloud media preserved).'),
        ),
      );
    }
  }

  Future<void> _confirmClearAllCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Clear all local cache?'),
        content: const Text(
          'This will remove temporary thumbnail images, streaming video chunks, and local downloads from this device.\n\n'
          'Your photos, videos, and files stored in Telegram Saved Messages will NOT be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear Cache'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _cacheManager.clearAllCache();
      await _loadAllStats();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('All local cache cleared successfully.'),
          ),
        );
      }
    }
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Log out of Nuvex?'),
        content: const Text(
          'You will be disconnected from this session.\n\n'
          'All your photos, videos, and files remain completely safe in your Telegram Saved Messages cloud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _authController.logout();
      if (mounted) {
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil(NuvexRoutes.gettingStarted, (route) => false);
      }
    }
  }

  void _navigateToCollection(String title, String categoryKey) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CollectionDetailScreen(
          title: title,
          categoryKey: categoryKey,
          repository: _mediaController.repository,
          mediaController: _mediaController,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = _authController.currentUser;
    final displayName = user?.displayName ?? 'Telegram User';
    final initial = displayName.trim().isNotEmpty
        ? displayName.trim()[0].toUpperCase()
        : 'U';
    final username = user?.username;
    final phone = user?.phone ?? _authController.currentPhoneNumber;

    return Scaffold(
      backgroundColor: NuvexColors.iceBackground,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: NuvexColors.darkNavy,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Account & Storage',
          style: TextStyle(
            fontFamily: NuvexTypography.primaryFamily,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: NuvexColors.darkNavy,
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _authController.refreshCurrentUser();
          await _loadAllStats();
        },
        color: NuvexColors.primaryBlue,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isLoadingStats)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: NuvexColors.primaryBlue,
                    backgroundColor: Color(0xFFEFF6FF),
                  ),
                ),

              // ── 1. Profile Header ──
              _buildProfileHeader(
                displayName: displayName,
                initial: initial,
                username: username,
                phone: phone,
                userId: user?.id,
              ),

              const SizedBox(height: 20),

              // ── 2. Google Photos-Style Storage Card ──
              _buildStorageCard(),

              const SizedBox(height: 24),

              // ── 3. Storage Details Drill-down ──
              _buildSectionTitle('Storage Details'),
              const SizedBox(height: 10),
              _buildStorageDetailsCard(),

              const SizedBox(height: 24),

              // ── 4. Telegram Sync Controls ──
              _buildSectionTitle('Telegram Synchronization'),
              const SizedBox(height: 10),
              _buildSyncCard(),

              const SizedBox(height: 24),

              // ── 5. Local Cache Management ──
              _buildSectionTitle('Device Cache Management'),
              const SizedBox(height: 10),
              _buildCacheCard(),

              const SizedBox(height: 24),

              // ── 6. App Settings ──
              _buildSectionTitle('Settings'),
              const SizedBox(height: 10),
              _buildSettingsCard(),

              const SizedBox(height: 24),

              // ── 7. Account & Session ──
              _buildSectionTitle('Session & Security'),
              const SizedBox(height: 10),
              _buildSessionCard(),

              const SizedBox(height: 24),

              // ── 8. About & System ──
              _buildAboutCard(),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontFamily: NuvexTypography.primaryFamily,
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: NuvexColors.darkNavy,
        letterSpacing: -0.2,
      ),
    );
  }

  // ── Profile Header ──
  Widget _buildProfileHeader({
    required String displayName,
    required String initial,
    String? username,
    String? phone,
    int? userId,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Avatar Circle
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: NuvexColors.primaryBlue,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFDBEAFE), width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x182563EB),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Text(
                initial,
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: const TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: NuvexColors.darkNavy,
                    letterSpacing: -0.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (username != null && username.isNotEmpty)
                  Text(
                    '@$username',
                    style: const TextStyle(
                      fontFamily: NuvexTypography.primaryFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: NuvexColors.primaryBlue,
                    ),
                  ),
                if (phone != null && phone.isNotEmpty)
                  Text(
                    phone,
                    style: const TextStyle(
                      fontFamily: NuvexTypography.primaryFamily,
                      fontSize: 13,
                      color: NuvexColors.secondaryText,
                    ),
                  ),
                if (userId != null && userId > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'ID: $userId',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh account info',
            onPressed: _isRefreshingProfile ? null : _refreshAccountInfo,
            icon: _isRefreshingProfile
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(
                    Icons.refresh_rounded,
                    color: NuvexColors.secondaryText,
                    size: 22,
                  ),
          ),
        ],
      ),
    );
  }

  // ── Google Photos-Style Storage Card ──
  Widget _buildStorageCard() {
    final totalBytes = _storageStats.totalBytes;
    final totalCount = _storageStats.totalCount;

    final photosBytes = _storageStats.photos.totalBytes;
    final videosBytes = _storageStats.videos.totalBytes;
    final docsBytes = _storageStats.documents.totalBytes;
    final otherBytes = _storageStats.other.totalBytes;

    final hasData = totalBytes > 0;
    final pRatio = hasData ? (photosBytes / totalBytes) : 0.0;
    final vRatio = hasData ? (videosBytes / totalBytes) : 0.0;
    final dRatio = hasData ? (docsBytes / totalBytes) : 0.0;
    final oRatio = hasData ? (otherBytes / totalBytes) : 0.0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.cloud_outlined,
                      color: NuvexColors.primaryBlue,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Cloud Storage',
                    style: TextStyle(
                      fontFamily: NuvexTypography.primaryFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: NuvexColors.darkNavy,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$totalCount files',
                  style: const TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Large Headline for Used Storage
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                formatBytes(totalBytes),
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: NuvexColors.darkNavy,
                  letterSpacing: -1.0,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'used in Telegram',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: NuvexColors.secondaryText,
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          // Explicit Quota Notice (No fake numbers)
          Row(
            children: const [
              Icon(
                Icons.info_outline_rounded,
                size: 14,
                color: Color(0xFF64748B),
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Cloud storage quota not provided • Telegram Saved Messages',
                  style: TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 12,
                    color: Color(0xFF64748B),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 18),

          // Multi-Segment Visual Breakdown Bar
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 12,
              child: hasData
                  ? Row(
                      children: [
                        if (pRatio > 0)
                          Expanded(
                            flex: (pRatio * 1000).round().clamp(1, 1000),
                            child: Container(
                              color: const Color(0xFF2563EB),
                            ), // Photos
                          ),
                        if (vRatio > 0)
                          Expanded(
                            flex: (vRatio * 1000).round().clamp(1, 1000),
                            child: Container(
                              color: const Color(0xFF8B5CF6),
                            ), // Videos
                          ),
                        if (dRatio > 0)
                          Expanded(
                            flex: (dRatio * 1000).round().clamp(1, 1000),
                            child: Container(
                              color: const Color(0xFFF59E0B),
                            ), // Docs
                          ),
                        if (oRatio > 0)
                          Expanded(
                            flex: (oRatio * 1000).round().clamp(1, 1000),
                            child: Container(
                              color: const Color(0xFF10B981),
                            ), // Other
                          ),
                      ],
                    )
                  : Container(color: const Color(0xFFE2E8F0)),
            ),
          ),

          const SizedBox(height: 18),

          // Legend Items
          _buildStorageLegendItem(
            color: const Color(0xFF2563EB),
            label: 'Photos',
            sizeStr: formatBytes(photosBytes),
            count: _storageStats.photos.count,
            onTap: () => _navigateToCollection('Photos', 'photos'),
          ),
          const Divider(height: 16, color: Color(0xFFF1F5F9)),
          _buildStorageLegendItem(
            color: const Color(0xFF8B5CF6),
            label: 'Videos',
            sizeStr: formatBytes(videosBytes),
            count: _storageStats.videos.count,
            onTap: () => _navigateToCollection('Videos', 'videos'),
          ),
          const Divider(height: 16, color: Color(0xFFF1F5F9)),
          _buildStorageLegendItem(
            color: const Color(0xFFF59E0B),
            label: 'Documents & Files',
            sizeStr: formatBytes(docsBytes),
            count: _storageStats.documents.count,
            onTap: () => _navigateToCollection('Documents', 'documents'),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageLegendItem({
    required Color color,
    required String label,
    required String sizeStr,
    required int count,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: NuvexColors.darkNavy,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '($count)',
              style: const TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 13,
                color: NuvexColors.secondaryText,
              ),
            ),
            const Spacer(),
            Text(
              sizeStr,
              style: const TextStyle(
                fontFamily: NuvexTypography.primaryFamily,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: NuvexColors.darkNavy,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: Color(0xFF94A3B8),
            ),
          ],
        ),
      ),
    );
  }

  // ── Storage Details Card ──
  Widget _buildStorageDetailsCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: Column(
          children: [
            _buildDrillDownRow(
              icon: Icons.photo_library_outlined,
              iconColor: const Color(0xFF2563EB),
              title: 'Photos',
              subtitle:
                  '${_storageStats.photos.count} items • ${formatBytes(_storageStats.photos.totalBytes)}',
              onTap: () => _navigateToCollection('Photos', 'photos'),
            ),
            const Divider(height: 1, indent: 56, color: Color(0xFFF1F5F9)),
            _buildDrillDownRow(
              icon: Icons.videocam_outlined,
              iconColor: const Color(0xFF8B5CF6),
              title: 'Videos',
              subtitle:
                  '${_storageStats.videos.count} items • ${formatBytes(_storageStats.videos.totalBytes)}',
              onTap: () => _navigateToCollection('Videos', 'videos'),
            ),
            const Divider(height: 1, indent: 56, color: Color(0xFFF1F5F9)),
            _buildDrillDownRow(
              icon: Icons.description_outlined,
              iconColor: const Color(0xFFF59E0B),
              title: 'Files & Documents',
              subtitle:
                  '${_storageStats.documents.count} items • ${formatBytes(_storageStats.documents.totalBytes)}',
              onTap: () => _navigateToCollection('Documents', 'documents'),
            ),
            const Divider(height: 1, indent: 56, color: Color(0xFFF1F5F9)),
            _buildDrillDownRow(
              icon: Icons.history_rounded,
              iconColor: const Color(0xFF10B981),
              title: 'Recently Added',
              subtitle: 'Media indexed in the past 7 days',
              onTap: () =>
                  _navigateToCollection('Recently Added', 'recently_added'),
            ),
            const Divider(height: 1, indent: 56, color: Color(0xFFF1F5F9)),
            _buildDrillDownRow(
              icon: Icons.storage_rounded,
              iconColor: const Color(0xFFEC4899),
              title: 'Largest Files',
              subtitle: 'Sort all media by descending file size',
              onTap: () =>
                  _navigateToCollection('Largest Files', 'largest_files'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrillDownRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: NuvexTypography.primaryFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: NuvexColors.darkNavy,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          fontFamily: NuvexTypography.primaryFamily,
          fontSize: 12,
          color: NuvexColors.secondaryText,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: Color(0xFF94A3B8),
        size: 20,
      ),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  // ── Telegram Synchronization Card ──
  Widget _buildSyncCard() {
    final isSyncing = _mediaController.isSyncing;
    final lastSync = _mediaController.recentMedia.isNotEmpty
        ? 'Recently'
        : 'Never';
    final count = _mediaController.recentMedia.length;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isSyncing
                      ? const Color(0xFFEFF6FF)
                      : const Color(0xFFF1F5F9),
                  shape: BoxShape.circle,
                ),
                child: isSyncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NuvexColors.primaryBlue,
                        ),
                      )
                    : const Icon(
                        Icons.sync_rounded,
                        color: NuvexColors.primaryBlue,
                        size: 20,
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isSyncing
                          ? 'Synchronizing media...'
                          : 'Sync with Telegram',
                      style: const TextStyle(
                        fontFamily: NuvexTypography.primaryFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: NuvexColors.darkNavy,
                      ),
                    ),
                    Text(
                      isSyncing
                          ? 'Fetching latest Saved Messages batches'
                          : '$count items indexed • Last synced: $lastSync',
                      style: const TextStyle(
                        fontFamily: NuvexTypography.primaryFamily,
                        fontSize: 12,
                        color: NuvexColors.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const ValueKey('sync_now_button'),
              onPressed: isSyncing ? null : _handleSyncNow,
              style: ElevatedButton.styleFrom(
                backgroundColor: NuvexColors.primaryBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              icon: isSyncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: Text(
                isSyncing ? 'Syncing...' : 'Sync Now',
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Device Cache Management Card ──
  Widget _buildCacheCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total Nuvex Cache',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: NuvexColors.darkNavy,
                ),
              ),
              Text(
                formatBytes(_cacheInfo.totalCacheBytes),
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: NuvexColors.primaryBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildCacheRow(
            'Thumbnail Cache',
            formatBytes(_cacheInfo.thumbnailCacheBytes),
            onClear: _clearThumbnailCache,
          ),
          const Divider(height: 16, color: Color(0xFFF1F5F9)),
          _buildCacheRow(
            'Video Streaming Chunks',
            formatBytes(_cacheInfo.videoCacheBytes),
            onClear: _clearVideoCache,
          ),
          const Divider(height: 16, color: Color(0xFFF1F5F9)),
          _buildCacheRow(
            'Downloaded Media Copies',
            formatBytes(_cacheInfo.mediaCacheBytes),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('clear_all_cache_button'),
              onPressed: _confirmClearAllCache,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Color(0xFFFECDD3)),
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.cleaning_services_rounded, size: 18),
              label: const Text(
                'Clear All Local Cache',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCacheRow(String label, String sizeStr, {VoidCallback? onClear}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: NuvexTypography.primaryFamily,
              fontSize: 13,
              color: NuvexColors.secondaryText,
            ),
          ),
        ),
        Text(
          sizeStr,
          style: const TextStyle(
            fontFamily: NuvexTypography.primaryFamily,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: NuvexColors.darkNavy,
          ),
        ),
        if (onClear != null) ...[
          const SizedBox(width: 8),
          InkWell(
            onTap: onClear,
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                'Clear',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: NuvexColors.primaryBlue,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ── Settings Card ──
  Widget _buildSettingsCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: Column(
          children: [
            SwitchListTile(
              title: const Text(
                'Automatic Background Sync',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: NuvexColors.darkNavy,
                ),
              ),
              subtitle: const Text(
                'Keep Saved Messages metadata in sync when opening the app',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 12,
                  color: NuvexColors.secondaryText,
                ),
              ),
              value: _autoSync,
              activeThumbColor: NuvexColors.primaryBlue,
              onChanged: (val) => setState(() => _autoSync = val),
            ),
            const Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: Color(0xFFF1F5F9),
            ),
            SwitchListTile(
              title: const Text(
                'Wi-Fi Only Media Loading',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: NuvexColors.darkNavy,
                ),
              ),
              subtitle: const Text(
                'Prevent heavy video streaming over cellular data',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 12,
                  color: NuvexColors.secondaryText,
                ),
              ),
              value: _wifiOnly,
              activeThumbColor: NuvexColors.primaryBlue,
              onChanged: (val) => setState(() => _wifiOnly = val),
            ),
            const Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: Color(0xFFF1F5F9),
            ),
            SwitchListTile(
              title: const Text(
                'App Notifications',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: NuvexColors.darkNavy,
                ),
              ),
              subtitle: const Text(
                'Alerts for upload and sync completions',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 12,
                  color: NuvexColors.secondaryText,
                ),
              ),
              value: _notifications,
              activeThumbColor: NuvexColors.primaryBlue,
              onChanged: (val) => setState(() => _notifications = val),
            ),
          ],
        ),
      ),
    );
  }

  // ── Session Card ──
  Widget _buildSessionCard() {
    final isConnected = _authController.telegramService.isConnected;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isConnected ? const Color(0xFF10B981) : Colors.amber,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isConnected ? 'Active Telegram Session' : 'Reconnecting...',
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: NuvexColors.darkNavy,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'DC ${_authController.telegramService.currentDc.id}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF64748B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const ValueKey('logout_button'),
              onPressed: _confirmLogout,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFF1F2),
                foregroundColor: Colors.redAccent,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFFFECDD3)),
                ),
              ),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text(
                'Log Out of Nuvex',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── About Card ──
  Widget _buildAboutCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Text(
                'Nuvex',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: NuvexColors.primaryBlue,
                ),
              ),
              SizedBox(width: 8),
              Text(
                'v1.0.0 (Build 1)',
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: NuvexColors.secondaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'High-performance personal media vault with direct Telegram MTProto 2.0 cloud storage.',
            style: TextStyle(
              fontFamily: NuvexTypography.primaryFamily,
              fontSize: 12,
              color: Color(0xFF64748B),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Protected with .nomedia sandbox and AES hardware encrypted session keys.',
            style: TextStyle(
              fontFamily: NuvexTypography.primaryFamily,
              fontSize: 11,
              color: Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }
}
