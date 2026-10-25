import 'dart:async';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/router.dart';
import 'core/services/native_media_service.dart';
import 'features/auth/controllers/auth_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Bounded image cache: sized to retain ~45 rows (180 items) of grid thumbnails in memory
  // without triggering Android Dalvik/ART GC pauses or memory pressure during scrolling.
  PaintingBinding.instance.imageCache.maximumSize = 180;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      50 * 1024 * 1024; // 50MB

  // Non-blocking background cache maintenance
  unawaited(NativeMediaService.cleanupUnwantedGalleryFiles());

  // Restore session before the first visible app frame
  final authController = AuthController();
  await authController.initialize();

  const envInitialRoute = String.fromEnvironment('INITIAL_ROUTE');
  final initialRoute = envInitialRoute.isNotEmpty
      ? envInitialRoute
      : (authController.isAuthenticated
            ? NuvexRoutes.home
            : NuvexRoutes.gettingStarted);

  runApp(NuvexApp(initialRoute: initialRoute, authController: authController));
}
