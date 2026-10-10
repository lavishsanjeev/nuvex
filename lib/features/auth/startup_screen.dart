import 'package:flutter/material.dart';

import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/services/native_media_service.dart';
import '../home/home_screen.dart';
import 'controllers/auth_controller.dart';

/// Clean startup router for Nuvex.
///
/// Ensures authenticated users launch directly into Photos without seeing a Nuvex
/// loading screen or spinner. If unauthenticated, smoothly routes to Getting Started.
class StartupScreen extends StatefulWidget {
  final AuthController? controller;

  const StartupScreen({super.key, this.controller});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  late final AuthController _authController;

  @override
  void initState() {
    super.initState();
    _authController = widget.controller ?? AuthController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkSession();
    });
  }

  Future<void> _checkSession() async {
    NativeMediaService.cleanupUnwantedGalleryFiles();
    if (!_authController.isInitialized) {
      await _authController.initialize();
    }
    if (!mounted) return;

    if (_authController.isAuthenticated) {
      Navigator.of(context)
          .pushReplacementNamed(NuvexRoutes.home, arguments: _authController);
    } else {
      Navigator.of(context).pushReplacementNamed(
        NuvexRoutes.gettingStarted,
        arguments: _authController,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_authController.isAuthenticated) {
      return HomeScreen(controller: _authController);
    }
    // Clean neutral scaffold with zero spinners or loading screens
    return const Scaffold(
      backgroundColor: NuvexColors.white,
      body: SizedBox.shrink(),
    );
  }
}
