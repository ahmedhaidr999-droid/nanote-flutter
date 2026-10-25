import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/collections/document.dart';
import '../../../../core/database/collections/folder.dart';
import '../../data/library_repository.dart';

/// Long-press sheet for one document: Pin / Rename / Move / Delete.
///
/// LIFETIME RULE (applies to every handler here): the sheet's `ref` dies
/// with the sheet. Every handler captures `ref.read(libraryRepositoryProvider
/// .future)` FIRST — while still mounted — then pops and awaits the
/// captured FUTURE. Follow-up dialogs receive the future, never the ref.
Future<void> showDocumentActions(
  BuildContext context,
  WidgetRef ref,
  Document document,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _DocumentActionsSheet(document: document),
  );
}

class _DocumentActionsSheet extends ConsumerWidget {
  const _DocumentActionsSheet({required this.document});

  final Document document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  document.title,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${document.type == DocumentType.pdf ? 'PDF' : 'Notebook'} · '
                  '${document.pageCount} ${document.pageCount == 1 ? 'page' : 'pages'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          ListTile(
            leading: Icon(document.pinned
                ? Icons.push_pin_outlined
                : Icons.push_pin),
            title: Text(document.pinned ? 'Unpin' : 'Pin to top'),
            onTap: () {
              final repoFuture = ref.read(libraryRepositoryProvider.future);
              Navigator.of(context).pop();
              repoFuture.then(
                (repo) => repo.setDocumentPinned(document, !document.pinned),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename'),
            onTap: () {
              final repoFuture = ref.read(libraryRepositoryProvider.future);
              Navigator.of(context).pop();
              showRenameDialog(
                context,
                title: 'Rename document',
                initial: document.title,
                onSaved: (name) async {
                  final repo = await repoFuture;
                  await repo.renameDocument(document, name);
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: const Text('Move to folder'),
            onTap: () {
              Navigator.of(context).pop();
              showMovePicker(context, document: document);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Move to Trash'),
            textColor: Theme.of(context).colorScheme.error,
            iconColor: Theme.of(context).colorScheme.error,
            onTap: () {
              final repoFuture = ref.read(libraryRepositoryProvider.future);
              Navigator.of(context).pop();
              _confirmDelete(context, repoFuture, document);
            },
          ),
        ],
      ),
    );
  }
}

void _confirmDelete(
  BuildContext context,
  Future<LibraryRepository> repoFuture,
  Document document,
) {
  // Capture BEFORE any pop — sheet/dialog contexts die with their route.
  final messenger = ScaffoldMessenger.maybeOf(context);
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Move to Trash?'),
      content: Text(
        '“${document.title}” will move to Trash. You can restore it from '
        'there, or delete it forever.',
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(dialogContext).pop,
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          onPressed: () {
            Navigator.of(dialogContext).pop();
            repoFuture.then((repo) => repo.trashDocument(document));
            messenger?.showSnackBar(
              SnackBar(
                content: Text('“${document.title}” moved to Trash'),
                duration: const Duration(seconds: 3),
              ),
            );
          },
          child: const Text('Move to Trash'),
        ),
      ],
    ),
  );
}

/// Long-press sheet for one folder: Rename / Move / Delete.
Future<void> showFolderActions(
  BuildContext context,
  WidgetRef ref,
  Folder folder,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _FolderActionsSheet(folder: folder),
  );
}

class _FolderActionsSheet extends ConsumerWidget {
  const _FolderActionsSheet({required this.folder});

  final Folder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                folder.name,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename'),
            onTap: () {
              final repoFuture = ref.read(libraryRepositoryProvider.future);
              Navigator.of(context).pop();
              showRenameDialog(
                context,
                title: 'Rename folder',
                initial: folder.name,
                onSaved: (name) async {
                  final repo = await repoFuture;
                  await repo.renameFolder(folder, name);
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: const Text('Move'),
            onTap: () {
              Navigator.of(context).pop();
              showMovePicker(context, folder: folder);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete'),
            textColor: Theme.of(context).colorScheme.error,
            iconColor: Theme.of(context).colorScheme.error,
            onTap: () {
              final repoFuture = ref.read(libraryRepositoryProvider.future);
              Navigator.of(context).pop();
              _confirmDeleteFolder(context, repoFuture, folder);
            },
          ),
        ],
      ),
    );
  }
}

void _confirmDeleteFolder(
  BuildContext context,
  Future<LibraryRepository> repoFuture,
  Folder folder,
) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete folder?'),
      content: Text(
        '“${folder.name}” and its subfolders will be deleted for good. '
        'Its notes move to Trash — you can restore them from there.',
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(dialogContext).pop,
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          onPressed: () {
            Navigator.of(dialogContext).pop();
            repoFuture.then((repo) => repo.deleteFolder(folder));
          },
          child: const Text('Delete'),
        ),
      ],
    ),
  );
}

/// Generic single-field text dialog (rename + "new folder" name entry).
Future<void> showRenameDialog(
  BuildContext context, {
  required String title,
  required String initial,
  required Future<void> Function(String name) onSaved,
  String confirmLabel = 'Rename',
}) {
  final controller = TextEditingController(text: initial);
  void submit(BuildContext dialogContext) {
    final name = controller.text.trim();
    Navigator.of(dialogContext).pop();
    if (name.isNotEmpty && name != initial) onSaved(name);
  }

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (_) => submit(dialogContext),
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(dialogContext).pop,
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => submit(dialogContext),
          child: Text(confirmLabel),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// "Move to folder" picker: the full folder tree as rows, plus a
/// "Library root" option. Moving a FOLDER disables itself + its descendants
/// (the repository enforces this too — the UI just communicates it).
Future<void> showMovePicker(
  BuildContext context, {
  Document? document,
  Folder? folder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _MovePickerSheet(document: document, folder: folder),
  );
}

class _MovePickerSheet extends ConsumerStatefulWidget {
  const _MovePickerSheet({this.document, this.folder});

  final Document? document;
  final Folder? folder;

  @override
  ConsumerState<_MovePickerSheet> createState() => _MovePickerSheetState();
}

class _MovePickerSheetState extends ConsumerState<_MovePickerSheet> {
  List<Folder>? _all;
  final Set<int> _blocked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Ref still mounted (we are the sheet).
    final repoFuture = ref.read(libraryRepositoryProvider.future);
    final folders = await repoFuture.then((r) => r.allFolders());

    // Moving a folder: block itself + every descendant.
    if (widget.folder != null) {
      final byParent = <int?, List<Folder>>{};
      for (final f in folders) {
        byParent.putIfAbsent(f.parentId, () => []).add(f);
      }
      final stack = <int>[widget.folder!.id];
      while (stack.isNotEmpty) {
        final id = stack.removeLast();
        _blocked.add(id);
        for (final child in byParent[id] ?? const <Folder>[]) {
          stack.add(child.id);
        }
      }
    }

    if (mounted) setState(() => _all = folders);
  }

  Future<void> _moveTo(int? parentId) async {
    // Everything needed after the await is captured synchronously here,
    // while the sheet is still mounted — this closure outlives its pops.
    final repoFuture = ref.read(libraryRepositoryProvider.future);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final nav = Navigator.of(context);
    final document = widget.document;
    final folder = widget.folder;

    final repo = await repoFuture;
    var ok = true;
    if (document != null) {
      await repo.moveDocument(document, parentId);
    } else if (folder != null) {
      ok = await repo.moveFolder(folder, parentId);
    }
    if (!ok) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('A folder cannot be moved into its own subtree.'),
        ),
      );
    }
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final currentParent = widget.document?.folderId ?? widget.folder?.parentId;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Choose a destination',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            if (all == null)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    ListTile(
                      enabled: currentParent != null,
                      leading: Icon(
                        Icons.home_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: const Text('Library root'),
                      onTap:
                          currentParent != null ? () => _moveTo(null) : null,
                    ),
                    ..._buildTree(all, null, currentParent),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildTree(
    List<Folder> all,
    int? parentId,
    int? currentParent, {
    int depth = 0,
  }) {
    final children =
        all.where((f) => f.parentId == parentId).toList(growable: false);
    return [
      for (final f in children)
        Column(
          children: [
            ListTile(
              enabled: !_blocked.contains(f.id) && currentParent != f.id,
              onTap:
                  _blocked.contains(f.id) || currentParent == f.id ? null
                      : () => _moveTo(f.id),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 16.0 + depth * 20),
              leading: _blocked.contains(f.id)
                  ? Icon(Icons.block,
                      size: 20, color: Theme.of(context).colorScheme.outline)
                  : Icon(
                      Icons.folder_outlined,
                      color: currentParent == f.id
                          ? Theme.of(context).colorScheme.outline
                          : Color(f.colorValue),
                    ),
              title: Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _blocked.contains(f.id) || currentParent == f.id
                      ? Theme.of(context).colorScheme.outline
                      : null,
                ),
              ),
              trailing: currentParent == f.id
                  ? Text(
                      'Current',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant),
                    )
                  : null,
            ),
            ..._buildTree(all, f.id, currentParent, depth: depth + 1),
          ],
        ),
    ];
  }
}
