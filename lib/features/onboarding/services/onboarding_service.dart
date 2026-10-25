import 'package:flutter/foundation.dart';

import '../../../core/storage/secure_storage.dart';

/// Service managing persistent onboarding guidance state in Nuvex.
///
/// Features:
/// - Persists guidance read/acknowledged status across app sessions.
/// - Drives dynamic unread notification badge state via [hasUnreadGuidance].
/// - Allows manual re-triggering from the notification bell at any time.
class OnboardingService {
  static final OnboardingService _instance = OnboardingService._internal();
  factory OnboardingService({NuvexSecureStore? secureStore}) {
    if (secureStore != null) {
      return OnboardingService._internal(secureStore: secureStore);
    }
    return _instance;
  }

  OnboardingService._internal({NuvexSecureStore? secureStore})
      : _secureStore = secureStore ?? NuvexSecureStore();

  final NuvexSecureStore _secureStore;
  static const _keyHasSeenGuidance = 'nuvex_has_seen_onboarding_guidance';

  final ValueNotifier<bool> hasUnreadGuidance = ValueNotifier<bool>(false);

  /// Initializes the service and checks whether guidance was already seen.
  Future<bool> initialize() async {
    try {
      final seen = await _secureStore.read(key: _keyHasSeenGuidance);
      final isSeen = seen == 'true';
      hasUnreadGuidance.value = !isSeen;
      return isSeen;
    } catch (_) {
      // In testing environments or when secure store platform channel is unavailable,
      // prevent unexpected modal popups from obscuring parent views.
      hasUnreadGuidance.value = false;
      return true;
    }
  }

  /// Marks onboarding guidance as read/acknowledged.
  Future<void> markOnboardingAsSeen() async {
    try {
      await _secureStore.write(key: _keyHasSeenGuidance, value: 'true');
      hasUnreadGuidance.value = false;
    } catch (e) {
      debugPrint('[ONBOARDING] Error marking guidance as seen: $e');
    }
  }

  /// Resets guidance state (e.g. for testing or app reset).
  Future<void> resetOnboarding() async {
    try {
      await _secureStore.delete(key: _keyHasSeenGuidance);
      hasUnreadGuidance.value = true;
    } catch (e) {
      debugPrint('[ONBOARDING] Error resetting guidance: $e');
    }
  }
}
