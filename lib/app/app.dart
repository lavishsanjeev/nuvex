import 'package:flutter/material.dart';

import '../features/auth/controllers/auth_controller.dart';
import 'router.dart';
import 'theme.dart';

/// Root application widget for Nuvex.
class NuvexApp extends StatelessWidget {
  final String initialRoute;
  final AuthController? authController;

  const NuvexApp({
    super.key,
    this.initialRoute = NuvexRoutes.initial,
    this.authController,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nuvex',
      theme: NuvexTheme.lightTheme,
      debugShowCheckedModeBanner: false,
      initialRoute: initialRoute,
      onGenerateRoute: (settings) => NuvexRouter.onGenerateRoute(
        settings,
        defaultAuthController: authController,
      ),
    );
  }
}
