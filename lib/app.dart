import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/user_profile.dart';
import 'providers/auth_provider.dart';
import 'ui/screens/login_screen.dart';
import 'ui/screens/notebook_list_screen.dart';

/// App root: theme and routing.
///
/// Signed out → [LoginScreen]; signed in → [NotebookListScreen].
/// Dashboard, Quick Run and the platform layouts are added in Phases 6–7.
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
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(authControllerProvider)) {
      AsyncData(value: final UserProfile user) => NotebookListScreen(
        key: ValueKey(user.id),
        user: user,
      ),
      _ => const LoginScreen(),
    };
  }
}
