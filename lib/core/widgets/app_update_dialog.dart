import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../services/app_update_model.dart';

/// Nuvex-branded dialog presented when a newer release is published on GitHub.
class AppUpdateDialog extends StatelessWidget {
  final UpdateManifest manifest;
  final SemanticVersion installedVersion;
  final VoidCallback onUpdateTap;

  const AppUpdateDialog({
    super.key,
    required this.manifest,
    required this.installedVersion,
    required this.onUpdateTap,
  });

  @override
  Widget build(BuildContext context) {
    final isForced = manifest.isForced(installedVersion);

    return PopScope(
      canPop: !isForced,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Container(
          decoration: BoxDecoration(
            color: NuvexColors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 32,
                offset: Offset(0, 12),
              ),
            ],
          ),
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Icon Header
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: Color(0xFFEFF6FF),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.system_update_rounded,
                    size: 32,
                    color: NuvexColors.primaryBlue,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title
              Text(
                isForced ? 'Important Update Required' : 'Update Available',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: NuvexColors.darkNavy,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 8),

              // Version Badge row
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'v$installedVersion  →  v${manifest.latestVersion}',
                    style: const TextStyle(
                      fontFamily: NuvexTypography.primaryFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: NuvexColors.secondaryText,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Release Notes / Summary
              if (manifest.releaseNotes != null &&
                  manifest.releaseNotes!.trim().isNotEmpty) ...[
                Container(
                  constraints: const BoxConstraints(maxHeight: 140),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Text(
                      manifest.releaseNotes!.trim(),
                      style: const TextStyle(
                        fontFamily: NuvexTypography.primaryFamily,
                        fontSize: 13,
                        color: NuvexColors.secondaryText,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ] else ...[
                const Text(
                  'A newer version of Nuvex is ready with performance improvements, bug fixes, and enhanced stability.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: NuvexTypography.primaryFamily,
                    fontSize: 14,
                    color: NuvexColors.secondaryText,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // Actions
              Row(
                children: [
                  if (!isForced) ...[
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          'Later',
                          style: TextStyle(
                            fontFamily: NuvexTypography.primaryFamily,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: NuvexColors.secondaryText,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        onUpdateTap();
                        if (!isForced) {
                          Navigator.of(context).pop();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: NuvexColors.primaryBlue,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Update',
                        style: TextStyle(
                          fontFamily: NuvexTypography.primaryFamily,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
