import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/collections/document.dart';
import '../../data/library_providers.dart';
import '../../data/library_repository.dart';

/// Trash (XNota parity) — every trashed document, restorable, or purge it
/// for good. Purely local: nothing leaves the device either way.
class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trashAsync = ref.watch(trashDocumentsProvider);
    final repoFuture = ref.read(libraryRepositoryProvider.future);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          trashAsync.maybeWhen(
            data: (docs) => docs.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Empty trash',
                    icon: const Icon(Icons.delete_forever_outlined),
                    onPressed: () => _confirmEmpty(context, repoFuture),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: trashAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load Trash:\n$e')),
        data: (docs) {
          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline_outlined,
                      size: 56, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text('Trash is empty'),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final doc = docs[i];
              return ListTile(
                leading: _DocBadge(doc: doc),
                title: Text(
                  doc.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${doc.type == DocumentType.pdf ? 'PDF' : 'Notebook'} · '
                  'trashed ${_shortDate(doc.trashedAt)}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Restore',
                      icon: const Icon(Icons.restore_outlined),
                      onPressed: () async {
                        final repo = await repoFuture;
                        await repo.restoreDocument(doc);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content:
                                    Text('“${doc.title}” restored')),
                          );
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Delete forever',
                      icon: Icon(Icons.delete_forever_outlined,
                          color: scheme.error),
                      onPressed: () => _confirmPurge(
                        context,
                        repoFuture,
                        doc,
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  static String _shortDate(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    if (diff.inDays < 30) return '${diff.inDays} d ago';
    final label = '${t.day}/${t.month}/${t.year}';
    return label;
  }

  static Future<void> _confirmPurge(
    BuildContext context,
    Future<LibraryRepository> repoFuture,
    Document doc,
  ) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete forever?'),
        content: Text(
          '“${doc.title}” and all its pages will be permanently removed '
          'from this device. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: Navigator.of(dialogContext).pop,
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor:
                  Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              repoFuture.then((repo) => repo.deleteDocument(doc));
            },
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
  }

  static Future<void> _confirmEmpty(
    BuildContext context,
    Future<LibraryRepository> repoFuture,
  ) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Empty trash?'),
        content: const Text(
          'Everything in Trash will be permanently removed from this '
          'device. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: Navigator.of(dialogContext).pop,
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor:
                  Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              repoFuture.then((repo) => repo.emptyTrash());
            },
            child: const Text('Empty trash'),
          ),
        ],
      ),
    );
  }
}

class _DocBadge extends StatelessWidget {
  const _DocBadge({required this.doc});

  final Document doc;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        doc.type == DocumentType.pdf
            ? Icons.picture_as_pdf_outlined
            : Icons.book_outlined,
        size: 22,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
