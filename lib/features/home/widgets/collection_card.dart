import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../models/collection_preview.dart';

/// Primary card for the Nuvex Collections screen (2x2 grid).
///
/// Categories:
/// - Documents
/// - Places
/// - Stickers
/// - Moments
///
/// Conforms to Google-Photos-style visual design while remaining Nuvex:
/// - When a real thumbnail exists:
///   - Real image fills the card with [BoxFit.cover]
///   - Large rounded corners
///   - Subtle bottom gradient overlay for crystal-clear readability
///   - Crisp white title and real item count at the bottom
///   - Category icon is hidden
/// - When no thumbnail exists (fallback / empty state):
///   - Clean Nuvex white background with subtle border and shadow
///   - Category icon shown in tinted rounded container
///   - Dark navy title and secondary gray count at the bottom
///   - Strictly NO fake images, NO mock counts
class CollectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final Color badgeBackground;
  final int? count;
  final String? thumbnailPath;
  final Widget? thumbnailWidget;
  final bool isLoading;
  final VoidCallback? onTap;

  const CollectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.badgeBackground,
    this.count,
    this.thumbnailPath,
    this.thumbnailWidget,
    this.isLoading = false,
    this.onTap,
  });

  /// Factory constructor to render a [CollectionCard] directly from a [CollectionPreview].
  factory CollectionCard.fromPreview(
    CollectionPreview preview, {
    Key? key,
    VoidCallback? onTap,
    Widget? thumbnailWidget,
  }) {
    return CollectionCard(
      key: key,
      title: preview.title,
      icon: preview.fallbackIcon,
      iconColor: preview.iconColor,
      badgeBackground: preview.badgeBackground,
      count: preview.itemCount,
      thumbnailPath: preview.thumbnailPath,
      thumbnailWidget: thumbnailWidget,
      isLoading: preview.isLoading,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    bool hasValidThumb = false;
    if (thumbnailPath != null && thumbnailPath!.trim().isNotEmpty) {
      try {
        final f = File(thumbnailPath!);
        hasValidThumb = f.existsSync() && f.lengthSync() > 0;
      } catch (_) {
        hasValidThumb = false;
      }
    }

    final bool showImage = thumbnailWidget != null || hasValidThumb;

    return Container(
      decoration: BoxDecoration(
        color: NuvexColors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9F0), width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            // ── Real thumbnail image layer (fills card as background) ──
            if (showImage)
              Positioned.fill(
                child:
                    thumbnailWidget ??
                    Image.file(
                      File(thumbnailPath!),
                      fit: BoxFit.cover,
                      cacheWidth: 500,
                      cacheHeight: 400,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
              ),

            // ── Subtle bottom gradient overlay for legibility ──
            if (showImage)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.72),
                      ],
                      stops: const [0.0, 0.40, 0.70, 1.0],
                    ),
                  ),
                ),
              ),

            // ── Subtle loading indicator when thumbnail is being fetched ──
            if (isLoading && !hasValidThumb && (count != null && count! > 0))
              const Positioned(
                top: 12,
                right: 12,
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ),

            // ── Content layer ──
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: showImage
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.spaceBetween,
                    children: [
                      // Tinted icon container: ONLY visible when no thumbnail exists
                      if (!showImage)
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: badgeBackground,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: Icon(icon, size: 20, color: iconColor),
                          ),
                        ),

                      // Title and Real Count at bottom
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontFamily: NuvexTypography.primaryFamily,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: showImage
                                  ? Colors.white
                                  : NuvexColors.darkNavy,
                              letterSpacing: -0.3,
                              height: 1.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (count != null && count! > 0) ...[
                            const SizedBox(height: 1),
                            Text(
                              '$count',
                              style: TextStyle(
                                fontFamily: NuvexTypography.primaryFamily,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: showImage
                                    ? Colors.white.withValues(alpha: 0.85)
                                    : NuvexColors.secondaryText,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
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
