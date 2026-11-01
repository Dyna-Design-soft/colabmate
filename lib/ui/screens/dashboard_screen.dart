import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/runtime_status.dart';
import '../../providers/runtime_provider.dart';
import '../widgets/output_viewer.dart';
import '../widgets/runtime_card.dart';

/// Colab dashboard (spec: runtime overview): plan, usage, running runtimes
/// with live GPU/RAM/disk, start a new runtime (CPU / GPU / TPU), connect,
/// stop, and a quick "hello" test.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(colabOverviewProvider);
    final controller = ref.read(colabOverviewProvider.notifier);
    final session = ref.watch(sessionControllerProvider);

    ref.listen(sessionControllerProvider.select((s) => s.error), (_, error) {
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$error'),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Colab'),
        bottom: session.busyMessage == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: const LinearProgressIndicator(),
              ),
      ),
      body: switch (overview) {
        AsyncData(value: final o) when o.needsGrant => _GrantView(
          onGrant: controller.grantAndLoad,
        ),
        AsyncData(:final value) => RefreshIndicator(
          onRefresh: controller.refresh,
          child: _OverviewList(overview: value, session: session),
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

class _OverviewList extends ConsumerWidget {
  const _OverviewList({required this.overview, required this.session});

  final ColabOverview overview;
  final SessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final usage = ref.watch(colabUsageProvider).value;
    final eligible = overview.specs.where((s) => s.eligible).toList()
      ..sort((a, b) => a.key.variant.index.compareTo(b.key.variant.index));
    final other = overview.specs.where((s) => !s.eligible).toList();
    final busy = session.busyMessage != null;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.workspace_premium_outlined),
            title: Text(overview.tier.label),
            subtitle: Text(_usageText(usage) ?? 'Your Colab plan'),
          ),
        ),
        if (session.busyMessage != null)
          Card(
            color: theme.colorScheme.secondaryContainer,
            child: ListTile(
              leading: const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(session.busyMessage!),
            ),
          ),
        const SizedBox(height: 8),
        _Header('Your runtimes', theme),
        if (overview.runtimes.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.power_settings_new),
              title: Text('No runtime running'),
              subtitle: Text('Start one below.'),
            ),
          ),
        for (final r in overview.runtimes)
          RuntimeCard(
            runtime: r,
            connected: session.connected && session.runtime?.name == r.name,
            status: session.runtime?.name == r.name ? session.status : null,
            busy: busy,
            onConnect: () =>
                ref.read(sessionControllerProvider.notifier).connect(r),
            onDisconnect: () =>
                ref.read(sessionControllerProvider.notifier).disconnect(),
            onStop: () => _confirmStop(context, ref, r),
          ),
        if (session.connected) const _HelloTest(),
        const SizedBox(height: 8),
        _Header('Start a runtime', theme),
        for (final s in eligible)
          Card(
            child: ListTile(
              leading: Icon(runtimeIcon(s.key.variant)),
              title: Text(s.key.label),
              subtitle: Text(s.key.shape.label),
              trailing: FilledButton.tonal(
                onPressed: busy
                    ? null
                    : () => _confirmStart(context, ref, s.key),
                child: const Text('Start'),
              ),
            ),
          ),
        if (other.isNotEmpty)
          ExpansionTile(
            title: Text('Not on your plan (${other.length})'),
            children: [
              for (final s in other)
                ListTile(
                  dense: true,
                  leading: Icon(runtimeIcon(s.key.variant)),
                  title: Text(s.key.label),
                  subtitle: Text(s.key.shape.label),
                ),
            ],
          ),
      ],
    );
  }

  static String? _usageText(ColabUsage? usage) {
    if (usage == null) return null;
    final parts = <String>[];
    if (usage.freeRemaining != null) {
      parts.add('${usage.freeRemaining!.toStringAsFixed(1)} free units left');
    } else if (usage.paidBalance > 0) {
      parts.add('${usage.paidBalance.toStringAsFixed(1)} compute units');
    }
    if (usage.consumptionRateHourly > 0) {
      parts.add('using ${usage.consumptionRateHourly.toStringAsFixed(2)}/h');
    }
    final mins = usage.minutesLeft;
    if (mins != null) parts.add('≈ ${mins ~/ 60} h ${mins % 60} min left');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Future<void> _confirmStart(
    BuildContext context,
    WidgetRef ref,
    RuntimeSpecKey spec,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Start ${spec.label}?'),
        content: Text(
          'Colab will assign a new ${spec.label} runtime (${spec.shape.label}). '
          '${spec.variant == RuntimeVariant.cpu ? '' : 'GPU/TPU time counts '
                    'towards your Colab usage limits. '}'
          'Stop it when you are done.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(sessionControllerProvider.notifier).startAndConnect(spec);
    }
  }

  Future<void> _confirmStop(
    BuildContext context,
    WidgetRef ref,
    RuntimeInfo runtime,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop ${runtime.spec.label}?'),
        content: const Text(
          'This releases the runtime. Running code stops and files on the '
          'runtime are deleted. A Colab browser tab using it will disconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop runtime'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(sessionControllerProvider.notifier).stop(runtime);
    }
  }
}

/// Spec Phase 4 step 23: run `print('hello ColabMate')` and show the output.
class _HelloTest extends ConsumerWidget {
  const _HelloTest();

  static const _id = '__dashboard_test__';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(cellRunsProvider(_id))[0];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "Test: print('hello ColabMate')",
                    style: TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                FilledButton.icon(
                  key: const Key('helloTest'),
                  onPressed: run?.running ?? false
                      ? null
                      : () => ref
                            .read(cellRunsProvider(_id).notifier)
                            .run(0, "print('hello ColabMate')"),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run'),
                ),
              ],
            ),
            if (run != null) ...[
              const Divider(),
              OutputViewer(run: run),
              if (run.done?.elapsed case final Duration t)
                Text(
                  'Done in ${t.inMilliseconds} ms',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
            ],
          ],
        ),
      ),
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
