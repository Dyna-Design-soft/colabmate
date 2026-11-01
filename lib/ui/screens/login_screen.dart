import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_exceptions.dart';
import '../../providers/auth_provider.dart';

/// Google sign-in screen. Shown while signed out (and while signing in/out);
/// once signed in, [ColabMateApp] switches to the notebook list.
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
