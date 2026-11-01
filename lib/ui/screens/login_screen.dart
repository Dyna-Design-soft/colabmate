import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_exceptions.dart';
import '../../models/user_profile.dart';
import '../../providers/auth_provider.dart';

/// Google sign-in screen.
///
/// Phase 2: also acts as the minimal auth test screen — after sign-in it shows
/// the user's name + photo and a Sign out button (gate tests A1–A6).
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: switch (auth) {
              AsyncData(value: final UserProfile user) => _SignedIn(
                user: user,
                onSignOut: controller.signOut,
              ),
              AsyncLoading() => const CircularProgressIndicator(),
              AsyncError(:final error) => _SignedOut(
                onSignIn: controller.signIn,
                error: error is AuthException ? error.message : '$error',
              ),
              _ => _SignedOut(onSignIn: controller.signIn),
            },
          ),
        ),
      ),
    );
  }
}

class _SignedOut extends StatelessWidget {
  const _SignedOut({required this.onSignIn, this.error});

  final VoidCallback onSignIn;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hub_outlined, size: 64, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text('ColabMate', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Sign in with the Google account you use for Colab.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 32),
        FilledButton.icon(
          key: const Key('signInButton'),
          onPressed: onSignIn,
          icon: const Icon(Icons.login),
          label: const Text('Sign in with Google'),
        ),
        if (error != null) ...[
          const SizedBox(height: 16),
          Text(
            error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }
}

class _SignedIn extends StatelessWidget {
  const _SignedIn({required this.user, required this.onSignOut});

  final UserProfile user;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = user.photoUrl;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 40,
          foregroundImage: photo == null ? null : NetworkImage(photo),
          child: Text(
            user.displayName.characters.first.toUpperCase(),
            style: theme.textTheme.headlineMedium,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          user.displayName,
          key: const Key('userName'),
          style: theme.textTheme.titleLarge,
        ),
        Text(user.email, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 32),
        OutlinedButton.icon(
          key: const Key('signOutButton'),
          onPressed: onSignOut,
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}
