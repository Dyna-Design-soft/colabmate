import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/runtime_status.dart';
import '../../providers/runtime_provider.dart';

/// Colab runtime overview (spec: dashboard).
///
/// Phase 4 step 1: checks that the official Colab API works for this
/// account — plan, available runtime types (CPU/GPU/TPU) and active
/// runtimes. Creating runtimes, running cells and live stats come next.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(colabOverviewProvider);
    final controller = ref.read(colabOverviewProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Colab')),
      body: switch (overview) {
        AsyncData(value: final o) when o.needsGrant => _GrantView(
          onGrant: controller.grantAndLoad,
        ),
        AsyncData(:final value) => RefreshIndicator(
          onRefresh: controller.refresh,
          child: _OverviewList(overview: value),
        ),
        AsyncError(:final error) => _ErrorView(
          error: error,
          onRetry: controller.refresh,
          onGrant: controller.grantAndLoad,
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _GrantView extends StatelessWidget {
  const _GrantView({required this.onGrant});

  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.memory, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Connect to Colab', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              'ColabMate needs permission to see and manage your Colab '
              'runtimes (choose CPU/GPU, run cells, check usage).',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('grantColab'),
              onPressed: onGrant,
              icon: const Icon(Icons.lock_open),
              label: const Text('Allow Colab access'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewList extends StatelessWidget {
  const _OverviewList({required this.overview});

  final ColabOverview overview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final specs = [...overview.specs]
      ..sort((a, b) {
        if (a.eligible != b.eligible) return a.eligible ? -1 : 1;
        return a.key.variant.index.compareTo(b.key.variant.index);
      });
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.workspace_premium_outlined),
            title: Text(overview.tier.label),
            subtitle: const Text('Your Colab plan'),
          ),
        ),
        const SizedBox(height: 12),
        _Header('Your runtimes', theme),
        if (overview.runtimes.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.power_settings_new),
              title: Text('No runtime running'),
              subtitle: Text('Starting a runtime from the app comes next.'),
            ),
          ),
        for (final r in overview.runtimes)
          Card(
            child: ListTile(
              leading: Icon(_icon(r.spec.variant)),
              title: Text(r.spec.label),
              subtitle: Text(
                [
                  r.spec.shape.label,
                  if (r.version != null) 'Runtime ${r.version}',
                ].where((s) => s.isNotEmpty).join(' · '),
              ),
              trailing: const Icon(Icons.circle, color: Colors.green, size: 12),
            ),
          ),
        const SizedBox(height: 12),
        _Header('Runtime types', theme),
        if (specs.isEmpty)
          const Card(
            child: ListTile(title: Text('No runtime types returned.')),
          ),
        for (final s in specs)
          Card(
            child: ListTile(
              leading: Icon(_icon(s.key.variant)),
              title: Text(s.key.label),
              subtitle: Text(s.key.shape.label),
              trailing: s.eligible
                  ? Chip(
                      label: const Text('Available'),
                      backgroundColor: theme.colorScheme.primaryContainer,
                    )
                  : const Chip(label: Text('Not on your plan')),
            ),
          ),
      ],
    );
  }

  static IconData _icon(RuntimeVariant v) => switch (v) {
    RuntimeVariant.gpu => Icons.developer_board,
    RuntimeVariant.tpu => Icons.grid_view,
    _ => Icons.memory,
  };
}

class _Header extends StatelessWidget {
  const _Header(this.text, this.theme);
  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: Text(text, style: theme.textTheme.titleSmall),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.error,
    required this.onRetry,
    required this.onGrant,
  });

  final Object error;
  final VoidCallback onRetry;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    final text = '$error';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            // Selectable so the exact error can be copied / screenshotted.
            SelectableText(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
                OutlinedButton(
                  onPressed: onGrant,
                  child: const Text('Allow Colab access'),
                ),
                TextButton(
                  onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                  child: const Text('Copy error'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
