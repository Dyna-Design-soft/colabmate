import 'package:flutter/material.dart';

import 'ui/screens/login_screen.dart';

/// App root: theme and routing.
///
/// Phase 2 only has the login/auth test screen. Dashboard, notebooks and the
/// platform layouts are added in Phases 6–7.
class ColabMateApp extends StatelessWidget {
  const ColabMateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ColabMate',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFF9AB00)),
      ),
      home: const LoginScreen(),
    );
  }
}
