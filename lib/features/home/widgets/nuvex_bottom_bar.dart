import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// Floating pill-shaped navigation bar for Nuvex.
///
/// Features:
/// - Rounded, pill-shaped dark surface floating above the bottom system navigation area
/// - Strictly displays exactly two destinations: Photos and Collections
/// - Selected tab highlighted with a subtle lighter pill
/// - Clean icons, balanced spacing, and smooth selection transitions
/// - Allows the photo grid to scroll behind and around it
class NuvexBottomBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const NuvexBottomBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E232E), // Sleek, dark pill surface
        borderRadius: BorderRadius.circular(NuvexSpacing.radiusFull),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 18,
            spreadRadius: 1,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FloatingNavItem(
            icon: currentIndex == 0
                ? Icons.photo_library_rounded
                : Icons.photo_library_outlined,
            label: 'Photos',
            isSelected: currentIndex == 0,
            onTap: () => onTap(0),
          ),
          const SizedBox(width: 4),
          _FloatingNavItem(
            icon: currentIndex == 1
                ? Icons.grid_view_rounded
                : Icons.grid_view_outlined,
            label: 'Collections',
            isSelected: currentIndex == 1,
            onTap: () => onTap(1),
          ),
        ],
      ),
    );
  }
}

class _FloatingNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _FloatingNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NuvexSpacing.radiusFull),
        splashColor: Colors.white.withValues(alpha: 0.15),
        highlightColor: Colors.transparent,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF333C4D) // Subtle lighter pill highlight
                : Colors.transparent,
            borderRadius: BorderRadius.circular(NuvexSpacing.radiusFull),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? Colors.white : const Color(0xFF94A3B8),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontFamily: NuvexTypography.primaryFamily,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
