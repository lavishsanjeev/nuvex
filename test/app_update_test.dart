import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nuvex/core/services/app_update_model.dart';
import 'package:nuvex/core/services/app_update_service.dart';
import 'package:nuvex/core/widgets/app_update_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SemanticVersion Unit Tests', () {
    test('Correctly parses semver strings and prefixes', () {
      final v1 = SemanticVersion.parse('1.0.0');
      expect(v1.major, 1);
      expect(v1.minor, 0);
      expect(v1.patch, 0);
      expect(v1.buildNumber, isNull);

      final v2 = SemanticVersion.parse('v2.4.12+35');
      expect(v2.major, 2);
      expect(v2.minor, 4);
      expect(v2.patch, 12);
      expect(v2.buildNumber, 35);
    });

    test('Non-lexicographical version comparisons (1.10.0 > 1.9.0)', () {
      final vSmall = SemanticVersion.parse('1.9.0');
      final vLarge = SemanticVersion.parse('1.10.0');

      expect(vLarge > vSmall, isTrue);
      expect(vSmall < vLarge, isTrue);
      expect(vSmall == vLarge, isFalse);
    });

    test('Build number differentiation when semver is equal', () {
      final b1 = SemanticVersion.parse('1.0.0+1');
      final b2 = SemanticVersion.parse('1.0.0+2');

      expect(b2 > b1, isTrue);
      expect(b1 < b2, isTrue);
    });
  });

  group('UpdateManifest Parsing & Policy Tests', () {
    test('Valid json parses all fields correctly', () {
      final json = {
        'latest_version': '1.2.0',
        'build_number': 15,
        'min_supported_version': '1.0.0',
        'is_mandatory': false,
        'release_date': '2026-10-23',
        'release_notes': 'Performance improvements and bug fixes.',
        'download_url': 'https://github.com/lavishsanjeev/Nuvex/releases/tag/v1.2.0',
        'apk_url': 'https://github.com/lavishsanjeev/Nuvex/releases/download/v1.2.0/nuvex.apk',
      };

      final manifest = UpdateManifest.fromJson(json);
      expect(manifest.latestVersion, equals(SemanticVersion.parse('1.2.0+15')));
      expect(manifest.minSupportedVersion, equals(SemanticVersion.parse('1.0.0')));
      expect(manifest.isMandatory, isFalse);
      expect(manifest.releaseNotes, contains('Performance improvements'));
      expect(manifest.apkUrl, contains('nuvex.apk'));
    });

    test('Malformed and missing fields fallback gracefully', () {
      final manifest = UpdateManifest.fromJson({});
      expect(manifest.latestVersion, equals(SemanticVersion.parse('0.0.0')));
      expect(manifest.minSupportedVersion, equals(SemanticVersion.parse('0.0.0')));
      expect(manifest.isMandatory, isFalse);
      expect(manifest.downloadUrl, isEmpty);
      expect(manifest.apkUrl, isEmpty);
    });

    test('Evaluates hasUpdate and isForced accurately', () {
      final manifest = UpdateManifest(
        latestVersion: SemanticVersion.parse('2.0.0'),
        minSupportedVersion: SemanticVersion.parse('1.5.0'),
        isMandatory: false,
        downloadUrl: 'https://example.com',
        apkUrl: 'https://example.com/app.apk',
      );

      final older = SemanticVersion.parse('1.0.0');
      final medium = SemanticVersion.parse('1.6.0');
      final newest = SemanticVersion.parse('2.0.0');

      // Older than minSupportedVersion => must update
      expect(manifest.hasUpdate(older), isTrue);
      expect(manifest.isForced(older), isTrue);

      // Between minSupported and latest => update available, not forced
      expect(manifest.hasUpdate(medium), isTrue);
      expect(manifest.isForced(medium), isFalse);

      // Up to date => no update
      expect(manifest.hasUpdate(newest), isFalse);
      expect(manifest.isForced(newest), isFalse);
    });
  });

  group('AppUpdateService Discovery & Throttling Tests', () {
    late AppUpdateService service;

    setUp(() {
      service = AppUpdateService();
      service.resetSessionState();
      AppUpdateService.mockFetchManifest = null;
    });

    tearDown(() {
      AppUpdateService.mockFetchManifest = null;
    });

    test('checkForUpdate parses successful mock manifest', () async {
      AppUpdateService.mockFetchManifest = (_) async => jsonEncode({
        'latest_version': '1.1.0',
        'build_number': 2,
        'min_supported_version': '1.0.0',
        'is_mandatory': false,
        'release_notes': 'Great update!',
        'download_url': 'https://github.com/lavishsanjeev/Nuvex/releases',
        'apk_url': 'https://github.com/lavishsanjeev/Nuvex/releases/app.apk',
      });

      final manifest = await service.checkForUpdate();
      expect(manifest, isNotNull);
      expect(manifest!.latestVersion, equals(SemanticVersion.parse('1.1.0+2')));
    });

    test('checkForUpdate returns null silently on network or parse failure', () async {
      AppUpdateService.mockFetchManifest = (_) async => throw Exception('Connection timeout');

      final manifest = await service.checkForUpdate();
      expect(manifest, isNull);
    });

    test('Throttles subsequent checks within 4 hours unless forced', () async {
      AppUpdateService.mockFetchManifest = (_) async => jsonEncode({
        'latest_version': '1.0.0',
        'build_number': 1,
      });

      expect(service.shouldCheck(), isTrue);
      await service.checkForUpdate();

      // Immediately after, throttled
      expect(service.shouldCheck(), isFalse);
      // Forced check ignores throttling
      expect(service.shouldCheck(force: true), isTrue);
    });
  });

  group('AppUpdateDialog UI Tests', () {
    testWidgets('Renders optional update dialog with Later and Update buttons', (tester) async {
      final manifest = UpdateManifest(
        latestVersion: SemanticVersion.parse('1.1.0'),
        minSupportedVersion: SemanticVersion.parse('1.0.0'),
        isMandatory: false,
        releaseNotes: 'Fixed offline startup and added shiny new logo.',
        downloadUrl: 'https://github.com/lavishsanjeev/Nuvex/releases',
        apkUrl: 'https://github.com/lavishsanjeev/Nuvex/releases/app.apk',
      );

      bool updateClicked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppUpdateDialog(
              manifest: manifest,
              installedVersion: SemanticVersion.parse('1.0.0'),
              onUpdateTap: () {
                updateClicked = true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Update Available'), findsOneWidget);
      expect(find.text('v1.0.0  →  v1.1.0'), findsOneWidget);
      expect(find.text('Fixed offline startup and added shiny new logo.'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(updateClicked, isTrue);
    });

    testWidgets('Renders mandatory update dialog without Later button', (tester) async {
      final manifest = UpdateManifest(
        latestVersion: SemanticVersion.parse('2.0.0'),
        minSupportedVersion: SemanticVersion.parse('2.0.0'),
        isMandatory: true,
        releaseNotes: 'Critical security update required.',
        downloadUrl: 'https://github.com/lavishsanjeev/Nuvex/releases',
        apkUrl: 'https://github.com/lavishsanjeev/Nuvex/releases/app.apk',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppUpdateDialog(
              manifest: manifest,
              installedVersion: SemanticVersion.parse('1.0.0'),
              onUpdateTap: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Important Update Required'), findsOneWidget);
      expect(find.text('Later'), findsNothing);
      expect(find.text('Update'), findsOneWidget);
    });
  });
}
