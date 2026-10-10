import 'dart:async';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/router.dart';
import 'core/services/native_media_service.dart';
import 'features/auth/controllers/auth_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Bounded image cache to prevent unconstrained memory usage and GC spikes during scrolling
  PaintingBinding.instance.imageCache.maximumSize = 150;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      40 * 1024 * 1024; // 40MB

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
