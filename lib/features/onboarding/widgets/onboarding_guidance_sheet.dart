import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../services/onboarding_service.dart';

/// Polished, Google Photos-inspired onboarding guidance bottom sheet.
///
/// Features:
/// - Concise explanation of Telegram vault, original-quality photos, and video streaming.
/// - Dismissible with gesture or action button.
/// - Persistently saves seen status via [OnboardingService].
/// - Fully responsive for all Android screen sizes and orientations.
class OnboardingGuidanceSheet extends StatelessWidget {
  final OnboardingService onboardingService;

  const OnboardingGuidanceSheet({
    super.key,
    required this.onboardingService,
  });

  /// Displays the guidance bottom sheet.
  static Future<void> show(
    BuildContext context, {
    OnboardingService? service,
  }) async {
    final activeService = service ?? OnboardingService();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => OnboardingGuidanceSheet(
        onboardingService: activeService,
      ),
    );
    await activeService.markOnboardingAsSeen();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      decoration: const BoxDecoration(
        color: NuvexColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 24,
            offset: Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            // Drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),

            // Scrollable Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: NuvexColors.primaryAccentLight,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.auto_awesome_rounded,
                            color: NuvexColors.primaryBlue,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Getting Started with Nuvex',
                                style: TextStyle(
                                  fontFamily: NuvexTypography.primaryFamily,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: NuvexColors.darkNavy,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Private cloud media vault',
                                style: TextStyle(
                                  fontFamily: NuvexTypography.primaryFamily,
                                  fontSize: 13,
                                  color: NuvexColors.secondaryText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Feature 1: Private Telegram Vault
                    _GuidanceCard(
                      icon: Icons.cloud_done_rounded,
                      iconBg: const Color(0xFFEFF6FF),
                      iconColor: const Color(0xFF2563EB),
                      title: 'Your Private Telegram Vault',
                      description:
                          'Nuvex connects directly to your private Telegram account. Your media lives safely in your Saved Messages or personal backup chat — with zero subscription fees and complete data ownership.',
                    ),
                    const SizedBox(height: 14),

                    // Feature 2: Original Quality Photos
                    _GuidanceCard(
                      icon: Icons.photo_size_select_actual_rounded,
                      iconBg: const Color(0xFFF5F3FF),
                      iconColor: const Color(0xFF7C3AED),
                      title: 'Original-Quality Photos',
                      description:
                          'Photos are uploaded as uncompressed MTProto documents to preserve 100% of your camera sensor\'s detail, full dynamic range, and EXIF metadata without compression.',
                    ),
                    const SizedBox(height: 14),

                    // Feature 3: Fast & Memory-Efficient Videos
                    _GuidanceCard(
                      icon: Icons.play_circle_filled_rounded,
                      iconBg: const Color(0xFFECFDF5),
                      iconColor: const Color(0xFF059669),
                      title: 'Fast & Memory-Efficient Videos',
                      description:
                          'Videos are uploaded with streaming attributes. Instant playback starts immediately using fast byte-range requests without draining device RAM or waiting for full downloads.',
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),

            // Action Button
            Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, bottomPadding > 0 ? bottomPadding : 16),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  key: const ValueKey('onboarding_guidance_dismiss_btn'),
                  onPressed: () {
                    onboardingService.markOnboardingAsSeen();
                    Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NuvexColors.primaryBlue,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Got It',
                    style: TextStyle(
                      fontFamily: NuvexTypography.primaryFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
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

class _GuidanceCard extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String title;
  final String description;

  const _GuidanceCard({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NuvexColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: NuvexColors.darkNavy,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  description,
                  style: const TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 13,
                    color: NuvexColors.secondaryText,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
