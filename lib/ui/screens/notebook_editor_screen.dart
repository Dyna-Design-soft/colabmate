import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/drive/drive_manager.dart';
import '../../models/notebook.dart';
import '../../providers/drive_provider.dart';

/// Notebook viewer with simple cell editing.
///
/// Phase 3 version: plain text editing, enough for the Drive gate tests
/// (D2, D4–D6). Phase 6 replaces the editor with Monaco and adds Run.
class NotebookEditorScreen extends ConsumerWidget {
  const NotebookEditorScreen({super.key, required this.id, required this.name});

  final String id;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notebook = ref.watch(notebookProvider(id));
    return Scaffold(
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: switch (notebook) {
        AsyncData(:final value) => _CellList(notebook: value),
        AsyncError(:final error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              error is DriveOfflineException
                  ? 'You are offline and this notebook has not been opened '
                        'on this device before.'
                  : '$error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _CellList extends ConsumerWidget {
  const _CellList({required this.notebook});

  final Notebook notebook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (notebook.pendingSync)
          Material(
            key: const Key('pendingSyncBanner'),
            color: scheme.tertiaryContainer,
            child: ListTile(
              leading: Icon(
                Icons.cloud_upload_outlined,
                color: scheme.onTertiaryContainer,
              ),
              title: Text(
                'Saved on this device — will upload to Drive when online.',
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
              subtitle: Text(
                'Your local edits will overwrite the Drive version on sync.',
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
            ),
          ),
        if (notebook.cells.isEmpty)
          const Padding(
            padding: EdgeInsets.all(48),
            child: Text(
              'This notebook has no cells.',
              textAlign: TextAlign.center,
            ),
          ),
        for (var i = 0; i < notebook.cells.length; i++)
          _CellCard(
            index: i,
            cell: notebook.cells[i],
            onEdit: () => _edit(context, ref, i, notebook.cells[i]),
          ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    int index,
    Cell cell,
  ) async {
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _CellEditorSheet(cell: cell),
    );
    if (text == null || text == cell.source) return;
    final error = await ref
        .read(notebookProvider(notebook.id).notifier)
        .saveCell(index, text);
    if (!context.mounted) return;
    final saved = ref.read(notebookProvider(notebook.id)).value;
    final message = error != null
        ? 'Saved on this device. Upload failed: $error'
        : saved?.pendingSync ?? false
        ? 'Saved offline. Will sync when you are back online.'
        : 'Saved to Google Drive.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _CellCard extends StatelessWidget {
  const _CellCard({
    required this.index,
    required this.cell,
    required this.onEdit,
  });

  final int index;
  final Cell cell;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCode = cell.type == CellType.code;
    final output = isCode ? cell.outputText : '';
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('cell-$index'),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    isCode ? 'Code' : 'Text',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                cell.source.isEmpty ? '(empty)' : cell.source,
                style: isCode
                    ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
                    : theme.textTheme.bodyMedium,
              ),
              if (output.isNotEmpty) ...[
                const Divider(height: 20),
                Text(
                  output,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CellEditorSheet extends StatefulWidget {
  const _CellEditorSheet({required this.cell});

  final Cell cell;

  @override
  State<_CellEditorSheet> createState() => _CellEditorSheetState();
}

class _CellEditorSheetState extends State<_CellEditorSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.cell.source,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCode = widget.cell.type == CellType.code;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                isCode ? 'Edit code cell' : 'Edit text cell',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('saveCell'),
                onPressed: () => Navigator.pop(context, _controller.text),
                child: const Text('Save'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: TextField(
              controller: _controller,
              autofocus: true,
              maxLines: null,
              minLines: 6,
              keyboardType: TextInputType.multiline,
              style: isCode
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 14)
                  : null,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ),
        ],
      ),
    );
  }
}
