import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/app_version.dart';
import '../widgets/app_update_dialog.dart';
import 'app_update_model.dart';
import 'native_media_service.dart';

/// Lightweight, production-hardened in-app update checking service for Nuvex.
///
/// Features:
/// - Direct GitHub release manifest discovery (`version.json`) without third-party plugins.
/// - Strict semantic version comparison (numeric major.minor.patch+build).
/// - Network resilience: timeouts, rate limits, and offline errors handled silently.
/// - Startup throttling: checks only once after the first frame, throttled per session.
/// - Respects user choice: optional updates dismissible, mandatory updates enforced.
/// - Zero credential exposure and completely isolated from Telegram auth.
class AppUpdateService {
  static final AppUpdateService _instance = AppUpdateService._internal();
  factory AppUpdateService() => _instance;
  AppUpdateService._internal();

  /// Mock hook for unit testing manifest fetches without real network calls.
  @visibleForTesting
  static Future<String> Function(String url)? mockFetchManifest;

  /// Current semantic version of the installed app.
  SemanticVersion get currentVersion => SemanticVersion(
        major: int.parse(AppVersion.currentVersion.split('.')[0]),
        minor: int.parse(AppVersion.currentVersion.split('.')[1]),
        patch: int.parse(AppVersion.currentVersion.split('.')[2]),
        buildNumber: AppVersion.currentBuildNumber,
      );

  DateTime? _lastCheckedAt;
  bool _dialogShownThisSession = false;

  /// Resets session tracking state (useful for tests or explicit manual checks).
  void resetSessionState() {
    _lastCheckedAt = null;
    _dialogShownThisSession = false;
  }

  /// Checks whether an update check should be throttled.
  /// Defaults to at most once per 4 hours unless [force] is true.
  bool shouldCheck({bool force = false}) {
    if (force) return true;
    if (_lastCheckedAt == null) return true;
    final diff = DateTime.now().difference(_lastCheckedAt!);
    return diff.inHours >= 4;
  }

  /// Fetches and parses the update manifest from the configured repository.
  Future<UpdateManifest?> checkForUpdate({
    String? manifestUrl,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final url = manifestUrl ?? AppVersion.updateManifestUrl;

    try {
      String body;
      if (mockFetchManifest != null) {
        body = await mockFetchManifest!(url);
      } else {
        final client = HttpClient();
        client.connectionTimeout = timeout;
        try {
          final uri = Uri.parse(url);
          final request = await client.getUrl(uri).timeout(timeout);
          request.headers.set('User-Agent', 'Nuvex-Android-Client');
          request.headers.set('Accept', 'application/json');

          final response = await request.close().timeout(timeout);
          if (response.statusCode != HttpStatus.ok) {
            debugPrint('[UPDATE] Manifest request failed with status: ${response.statusCode}');
            return null;
          }

          body = await response.transform(utf8.decoder).join();
        } finally {
          client.close();
        }
      }

      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) {
        debugPrint('[UPDATE] Malformed manifest: not a JSON object');
        return null;
      }

      final manifest = UpdateManifest.fromJson(json);
      _lastCheckedAt = DateTime.now();
      return manifest;
    } catch (e) {
      // Network failures, offline state, timeouts, and JSON errors are handled silently
      debugPrint('[UPDATE] Silent failure checking for updates: $e');
      return null;
    }
  }

  /// Runs an update check on startup and presents the branded dialog if a newer version is available.
  ///
  /// Guarantees:
  /// - Non-blocking: executed safely in the background.
  /// - Shown at most once per session for optional updates.
  /// - Never crashes or intercepts user interactions if offline.
  Future<void> checkAndShowPrompt(
    BuildContext context, {
    bool force = false,
  }) async {
    if (!force && (_dialogShownThisSession || !shouldCheck())) {
      return;
    }

    final manifest = await checkForUpdate();
    if (manifest == null) return;

    final installed = currentVersion;
    if (manifest.hasUpdate(installed)) {
      if (!context.mounted) return;
      if (!force && _dialogShownThisSession) return;

      _dialogShownThisSession = true;

      await showDialog<void>(
        context: context,
        barrierDismissible: !manifest.isForced(installed),
        builder: (ctx) => AppUpdateDialog(
          manifest: manifest,
          installedVersion: installed,
          onUpdateTap: () async {
            final targetUrl = manifest.apkUrl.isNotEmpty
                ? manifest.apkUrl
                : manifest.downloadUrl;
            await NativeMediaService.openUrl(targetUrl);
          },
        ),
      );
    }
  }
}
