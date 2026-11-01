import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/runtime_status.dart';
import '../../providers/runtime_provider.dart';

IconData runtimeIcon(RuntimeVariant v) => switch (v) {
  RuntimeVariant.gpu => Icons.developer_board,
  RuntimeVariant.tpu => Icons.grid_view,
  _ => Icons.memory,
};

/// A running Colab runtime with live GPU / RAM / disk bars (spec widget
/// `runtime_card.dart`, FR-03).
class RuntimeCard extends ConsumerWidget {
  const RuntimeCard({
    super.key,
    required this.runtime,
    required this.connected,
    required this.busy,
    required this.onConnect,
    required this.onDisconnect,
    required this.onStop,
    this.status,
  });

  final RuntimeInfo runtime;
  final bool connected;
  final bool busy;
  final KernelStatus? status;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final resources = ref.watch(runtimeResourcesProvider(runtime.name)).value;
    final (statusText, statusColor) = switch (status) {
      _ when !connected => ('Running', Colors.green),
      KernelStatus.busy => ('Connected · busy', Colors.orange),
      KernelStatus.starting => ('Reconnecting…', Colors.amber),
      KernelStatus.disconnected => ('Disconnected', theme.colorScheme.error),
      _ => ('Connected · idle', Colors.green),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(runtimeIcon(runtime.spec.variant)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        runtime.spec.label,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        runtime.spec.shape.label,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.circle, size: 10, color: statusColor),
                const SizedBox(width: 6),
                Text(statusText, style: theme.textTheme.labelMedium),
              ],
            ),
            const SizedBox(height: 12),
            if (resources == null)
              const LinearProgressIndicator(minHeight: 2)
            else ...[
              for (final (i, gpu) in resources.gpus.indexed) ...[
                _Meter(
                  label: resources.gpus.length > 1 ? 'GPU ${i + 1}' : 'GPU',
                  fraction: gpu.utilization,
                  detail: '${(gpu.utilization * 100).round()}%',
                ),
                _Meter(
                  label: 'GPU RAM',
                  fraction: gpu.memoryFraction,
                  detail:
                      '${_gb(gpu.memoryUsedBytes)} / ${_gb(gpu.memoryTotalBytes)}',
                  warn: gpu.memoryFraction > 0.9,
                ),
              ],
              _Meter(
                label: 'RAM',
                fraction: resources.ramFraction,
                detail:
                    '${_gb(resources.ramUsedBytes)} / ${_gb(resources.ramTotalBytes)}',
                warn: resources.ramFraction > 0.9,
              ),
              _Meter(
                label: 'Disk',
                fraction: resources.diskFraction,
                detail:
                    '${_gb(resources.diskUsedBytes)} / ${_gb(resources.diskTotalBytes)}',
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: busy ? null : onStop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop'),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(width: 8),
                if (connected)
                  OutlinedButton(
                    onPressed: busy ? null : onDisconnect,
                    child: const Text('Disconnect'),
                  )
                else
                  FilledButton(
                    key: ValueKey('connect-${runtime.id}'),
                    onPressed: busy ? null : onConnect,
                    child: const Text('Connect'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _gb(int bytes) =>
      '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _Meter extends StatelessWidget {
  const _Meter({
    required this.label,
    required this.fraction,
    required this.detail,
    this.warn = false,
  });

  final String label;
  final double fraction;
  final String detail;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: theme.textTheme.labelMedium),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction.clamp(0, 1),
                minHeight: 8,
                color: warn ? theme.colorScheme.error : null,
              ),
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              detail,
              textAlign: TextAlign.end,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}
