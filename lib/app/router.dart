import 'package:flutter/material.dart';

import '../features/account/account_screen.dart';
import '../features/auth/authenticated_screen.dart';
import '../features/auth/code_screen.dart';
import '../features/auth/controllers/auth_controller.dart';
import '../features/auth/login_page.dart';
import '../features/auth/password_screen.dart';
import '../features/auth/phone_screen.dart';
import '../features/auth/startup_screen.dart';
import '../features/auth/widgets/onboarding_screen.dart';
import '../features/home/home_screen.dart';

/// Central route names for Nuvex.
abstract class NuvexRoutes {
  static const String initial = '/';
  static const String gettingStarted = '/getting-started';
  static const String credentials = '/credentials';
  static const String phone = '/phone';
  static const String code = '/code';
  static const String password = '/password';
  static const String authenticated = '/authenticated';
  static const String home = '/home';
  static const String account = '/account';
}

/// Simple declarative navigation route generator.
abstract class NuvexRouter {
  static Route<dynamic> onGenerateRoute(
    RouteSettings settings, {
    AuthController? defaultAuthController,
  }) {
    final controller =
        settings.arguments as AuthController? ?? defaultAuthController;

    switch (settings.name) {
      case NuvexRoutes.account:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const AccountScreen(),
        );
      case NuvexRoutes.gettingStarted:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const OnboardingScreen(),
        );
      case NuvexRoutes.credentials:
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => LoginPage(controller: controller),
        );
      case NuvexRoutes.phone:
        final authController = controller ?? AuthController();
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => PhoneScreen(controller: authController),
        );
      case NuvexRoutes.code:
        final authController = controller ?? AuthController();
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => CodeScreen(controller: authController),
        );
      case NuvexRoutes.password:
        final authController = controller ?? AuthController();
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => Password2FAScreen(controller: authController),
        );
      case NuvexRoutes.authenticated:
        final authController = controller ?? AuthController();
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => AuthenticatedScreen(controller: authController),
        );
      case NuvexRoutes.home:
        final authController = controller ?? AuthController();
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => HomeScreen(controller: authController),
        );
      case NuvexRoutes.initial:
      default:
        if (controller != null && controller.isAuthenticated) {
          return MaterialPageRoute(
            settings: settings,
            builder: (_) => HomeScreen(controller: controller),
          );
        }
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => StartupScreen(controller: controller),
        );
    }
  }
}
