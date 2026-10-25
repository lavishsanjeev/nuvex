import 'dart:io';

import 'package:flutter/material.dart';

/// Premium, Google Photos-inspired skeleton loading experience for Nuvex.
///
/// Designed to provide immediate visual feedback while media is prepared:
/// - In the Media Viewer: Full-screen charcoal skeleton matching the exact media
///   aspect ratio with a restrained shimmer highlight, or an instant thumbnail preview
///   with a subtle shimmer overlay.
/// - In the Gallery: 4-column skeleton grid matching the gallery layout, sharing
///   a single animation controller.
/// - Completely visual-only: zero connection status or backend-specific text.
/// - Ultra-lightweight: pure Flutter AnimationController and linear gradients,
///   zero expensive blurs, shaders, or third-party dependencies.
/// - Automatically respects Android reduced-motion settings.
class NuvexLoadingView extends StatefulWidget {
  /// Whether the animation is displayed on an immersive dark surface (e.g. Media Viewer)
  /// or a clean light surface (e.g. Gallery / App Startup).
  final bool isDark;

  /// Optional custom size for fixed-size placeholder contexts.
  final double? size;

  /// Aspect ratio of the media being prepared (width / height).
  /// Preserves exact screen layout to prevent jumps when real media arrives.
  final double? aspectRatio;

  /// Optional local thumbnail path to display underneath the shimmer while
  /// full-resolution media is downloading or streaming.
  final String? thumbnailPath;

  /// Whether the media being prepared is a video.
  final bool isVideo;

  /// Whether to render a 4-column skeleton grid for initial gallery loading.
  final bool isGrid;

  const NuvexLoadingView({
    super.key,
    this.isDark = false,
    this.size,
    this.aspectRatio,
    this.thumbnailPath,
    this.isVideo = false,
    this.isGrid = false,
  });

  /// Factory constructor for the 4-column gallery skeleton grid.
  const NuvexLoadingView.galleryGrid({super.key})
      : isDark = false,
        size = null,
        aspectRatio = null,
        thumbnailPath = null,
        isVideo = false,
        isGrid = true;

  @override
  State<NuvexLoadingView> createState() => _NuvexLoadingViewState();
}

class _NuvexLoadingViewState extends State<NuvexLoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _shimmerAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    _shimmerAnimation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );

    _controller.repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disableAnimations && _controller.isAnimating) {
      _controller.stop();
    } else if (!disableAnimations && !_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: disableAnimations
            ? const AlwaysStoppedAnimation(0.5)
            : _shimmerAnimation,
        builder: (context, child) {
          final progress = disableAnimations ? 0.5 : _shimmerAnimation.value;

          if (widget.isGrid) {
            return _buildGallerySkeletonGrid(progress);
          }

          if (widget.isDark) {
            return _buildMediaViewerSkeleton(progress);
          }

          return _buildLightSkeleton(progress);
        },
      ),
    );
  }

  /// Full-screen media viewer skeleton matching expected aspect ratio.
  Widget _buildMediaViewerSkeleton(double progress) {
    final double targetRatio = widget.aspectRatio != null && widget.aspectRatio! > 0
        ? widget.aspectRatio!
        : (widget.isVideo ? 16 / 9 : 1.0);

    final bool hasValidThumbnail = widget.thumbnailPath != null &&
        widget.thumbnailPath!.isNotEmpty &&
        File(widget.thumbnailPath!).existsSync();

    return Center(
      child: AspectRatio(
        aspectRatio: targetRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Instant thumbnail preview if available on disk
              if (hasValidThumbnail)
                Image.file(
                  File(widget.thumbnailPath!),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      _buildCharcoalBase(progress),
                )
              else
                _buildCharcoalBase(progress),

              // 2. Subtle restrained shimmer sweep layer
              Positioned.fill(
                child: CustomPaint(
                  painter: _RestrainedShimmerPainter(
                    progress: progress,
                    isDark: true,
                    hasContentUnderneath: hasValidThumbnail,
                  ),
                ),
              ),

              // 3. Minimalist media type indicator icon if no thumbnail exists
              if (!hasValidThumbnail)
                Center(
                  child: Icon(
                    widget.isVideo
                        ? Icons.videocam_outlined
                        : Icons.image_outlined,
                    size: 40,
                    color: const Color(0xFF334155).withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Base charcoal fill for media viewer skeleton.
  Widget _buildCharcoalBase(double progress) {
    return Container(
      color: const Color(0xFF141920),
    );
  }

  /// 4-column skeleton grid matching the gallery layout for initial media sync.
  Widget _buildGallerySkeletonGrid(double progress) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.0),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          crossAxisSpacing: 2.5,
          mainAxisSpacing: 2.5,
          childAspectRatio: 1.0,
        ),
        itemCount: 16, // 4 clean rows of skeleton tiles
        itemBuilder: (context, index) {
          return CustomPaint(
            painter: _RestrainedShimmerPainter(
              progress: progress,
              isDark: false,
              hasContentUnderneath: false,
            ),
          );
        },
      ),
    );
  }

  /// Light mode skeleton card for startup or generic placeholders.
  Widget _buildLightSkeleton(double progress) {
    final double s = widget.size ?? 120.0;
    return Center(
      child: SizedBox(
        width: s,
        height: s,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: CustomPaint(
            painter: _RestrainedShimmerPainter(
              progress: progress,
              isDark: false,
              hasContentUnderneath: false,
            ),
          ),
        ),
      ),
    );
  }
}

/// Restrained, lightweight shimmer painter using a single linear gradient sweep.
/// Avoids heavy canvas blur, complex paths, or continuous repaints outside of RepaintBoundary.
class _RestrainedShimmerPainter extends CustomPainter {
  final double progress; // -1.0 to 2.0
  final bool isDark;
  final bool hasContentUnderneath;

  _RestrainedShimmerPainter({
    required this.progress,
    required this.isDark,
    required this.hasContentUnderneath,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    if (hasContentUnderneath) {
      // Subtle transparent highlight sweeping across the existing thumbnail
      final shimmerPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment(progress - 0.5, -0.2),
          end: Alignment(progress + 0.5, 0.2),
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(rect);

      canvas.drawRect(rect, shimmerPaint);
      return;
    }

    if (isDark) {
      // Dark Charcoal / Slate skeleton for Media Viewer
      final darkShimmerPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment(progress - 0.6, -0.3),
          end: Alignment(progress + 0.6, 0.3),
          colors: const [
            Color(0xFF141920),
            Color(0xFF222B36),
            Color(0xFF141920),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(rect);

      canvas.drawRect(rect, darkShimmerPaint);
    } else {
      // Light Neutral Gray skeleton for Gallery Grid
      final lightShimmerPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment(progress - 0.6, -0.3),
          end: Alignment(progress + 0.6, 0.3),
          colors: const [
            Color(0xFFF1F5F9),
            Color(0xFFE2E8F0),
            Color(0xFFF1F5F9),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(rect);

      canvas.drawRect(rect, lightShimmerPaint);
    }
  }

  @override
  bool shouldRepaint(_RestrainedShimmerPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.isDark != isDark ||
        oldDelegate.hasContentUnderneath != hasContentUnderneath;
  }
}
