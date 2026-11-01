import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/drive/drive_manager.dart';
import '../../models/notebook.dart';
import '../../models/user_profile.dart';
import '../../providers/drive_provider.dart';
import 'dashboard_screen.dart';
import 'notebook_editor_screen.dart';

/// Lists the user's .ipynb notebooks from Google Drive (Phase 3, FR-02).
/// Falls back to the on-device cache when offline (FR-05).
class NotebookListScreen extends ConsumerWidget {
  const NotebookListScreen({super.key, required this.user});

  final UserProfile user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listing = ref.watch(notebookListProvider);
    final sync = ref.watch(syncControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notebooks'),
        actions: [
          if (sync.syncing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (!sync.online)
            const Tooltip(
              message: 'Offline',
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Icon(Icons.cloud_off_outlined),
              ),
            ),
          IconButton(
            key: const Key('openColab'),
            tooltip: 'Colab runtimes',
            icon: const Icon(Icons.memory),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DashboardScreen()),
            ),
          ),
          _AccountMenu(user: user),
        ],
      ),
      body: switch (listing) {
        AsyncData(:final value) => _NotebookList(listing: value),
        AsyncError(:final error) => _ErrorView(
          message: '$error',
          onRetry: () => ref.read(notebookListProvider.notifier).refresh(),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
      bottomNavigationBar: sync.failed > 0
          ? Material(
              color: theme.colorScheme.errorContainer,
              child: SafeArea(
                child: ListTile(
                  leading: const Icon(Icons.sync_problem),
                  title: Text(
                    '${sync.failed} notebook(s) could not be uploaded.',
                  ),
                  trailing: TextButton(
                    onPressed: () =>
                        ref.read(syncControllerProvider.notifier).syncNow(),
                    child: const Text('Retry'),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

class _NotebookList extends ConsumerWidget {
  const _NotebookList({required this.listing});

  final NotebookListing listing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notebooks = listing.notebooks;
    return RefreshIndicator(
      onRefresh: () => ref.read(notebookListProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (listing.fromCache)
            const _Banner(
              icon: Icons.cloud_off_outlined,
              text: 'Offline — showing notebooks saved on this device.',
            ),
          if (notebooks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(48),
              child: Text(
                listing.fromCache
                    ? 'No notebooks saved on this device yet.'
                    : 'No .ipynb notebooks found in your Google Drive.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final nb in notebooks) _NotebookTile(meta: nb),
        ],
      ),
    );
  }
}

class _NotebookTile extends StatelessWidget {
  const _NotebookTile({required this.meta});

  final NotebookMeta meta;

  @override
  Widget build(BuildContext context) {
    final modified = meta.modifiedTime;
    return ListTile(
      key: ValueKey(meta.id),
      leading: const Icon(Icons.description_outlined),
      title: Text(meta.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: modified == null ? null : Text(formatAgo(modified)),
      trailing: meta.pendingSync
          ? const Tooltip(
              message: 'Edited offline — waiting to sync',
              child: Icon(Icons.cloud_upload_outlined),
            )
          : null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NotebookEditorScreen(id: meta.id, name: meta.name),
        ),
      ),
    );
  }
}

class _AccountMenu extends ConsumerWidget {
  const _AccountMenu({required this.user});

  final UserProfile user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = user.photoUrl;
    return PopupMenuButton<String>(
      tooltip: user.email,
      icon: CircleAvatar(
        radius: 16,
        foregroundImage: photo == null ? null : NetworkImage(photo),
        child: Text(user.displayName.characters.first.toUpperCase()),
      ),
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(user.displayName),
            subtitle: Text(user.email),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'signout',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Sign out'),
          ),
        ),
      ],
      onSelected: (value) async {
        if (value != 'signout') return;
        final pending = await pendingEditCount(ref);
        if (pending > 0 && context.mounted) {
          final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Sign out?'),
              content: Text(
                '$pending notebook(s) have edits that are not uploaded to '
                'Drive yet. Signing out will discard them.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          );
          if (ok != true) return;
        }
        await signOutAndClearCache(ref);
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: ListTile(
        dense: true,
        leading: Icon(icon, color: scheme.onSecondaryContainer),
        title: Text(text, style: TextStyle(color: scheme.onSecondaryContainer)),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
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
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// "just now", "5 min ago", "3 h ago", "2 days ago", or the date.
String formatAgo(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time.toLocal());
  if (diff.inMinutes < 1) return 'Edited just now';
  if (diff.inHours < 1) return 'Edited ${diff.inMinutes} min ago';
  if (diff.inDays < 1) return 'Edited ${diff.inHours} h ago';
  if (diff.inDays < 7) {
    return 'Edited ${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }
  final t = time.toLocal();
  return 'Edited ${t.year}-${_two(t.month)}-${_two(t.day)}';
}

String _two(int n) => n.toString().padLeft(2, '0');
