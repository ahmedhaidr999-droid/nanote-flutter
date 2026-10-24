import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/router.dart';
import '../../../../core/database/collections/document.dart';
import '../../../../core/database/collections/folder.dart';
import '../../../pdf/data/pdf_import_service.dart';
import '../../data/library_providers.dart';
import '../../data/library_repository.dart';
import '../../domain/library_models.dart';
import '../library_prefs.dart';
import '../widgets/create_notebook_sheet.dart';
import '../widgets/document_tile.dart';
import '../widgets/folder_tile.dart';
import '../widgets/library_action_sheets.dart';

/// The library shelf: folders + documents, grid or list, pinned first,
/// quick-find across the whole library, and the create / import flows.
///
/// The underlying query is index-driven (see LibraryRepository) — opening a
/// folder with thousands of items is an index scan, and the grid paints
/// thumbnails straight from disk files (never re-rendering PDFs).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, required this.folderId});

  /// `null` → the root shelf.
  final int? folderId;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _searchController = TextEditingController();
  bool _importing = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _importPdf() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final file = picked?.files.single;
    if (file == null) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _importing = true);
    try {
      final importService = await ref.read(pdfImportServiceProvider.future);
      final doc = await importService.importFromFile(
        sourcePath: file.path,
        sourceBytes: file.bytes,
        folderId: widget.folderId,
      );
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Imported “${doc.title}” · ${doc.pageCount} pages'),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _createFolder() {
    return showRenameDialog(
      context,
      title: 'New folder',
      initial: '',
      confirmLabel: 'Create',
      onSaved: (name) async {
        final repo = await ref.read(libraryRepositoryProvider.future);
        await repo.createFolder(parentId: widget.folderId, name: name);
      },
    );
  }

  Future<void> _openCreateMenu() {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.notebook_add_outlined),
              title: const Text('New notebook'),
              subtitle: const Text('Blank paper, ready for ink'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                showCreateNotebookSheet(context, folderId: widget.folderId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _createFolder();
              },
            ),
            ListTile(
              enabled: !_importing,
              leading: _importing
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file_outlined),
              title: Text(_importing ? 'Importing…' : 'Import PDF'),
              subtitle: const Text(
                'Annotate an existing PDF — fully offline',
              ),
              onTap: _importing
                  ? null
                  : () {
                      Navigator.of(sheetContext).pop();
                      _importPdf();
                    },
            ),
          ],
        ),
      ),
    );
  }

  void _openDocument(Document d) => openDocument(context, d.id);

  void _openFolder(Folder f) => openFolder(context, f.id);

  void _documentActions(Document d) => showDocumentActions(context, ref, d);

  void _folderActions(Folder f) => showFolderActions(context, ref, f);

  void _endSearch() {
    _searchController.clear();
    ref.read(libraryPrefsProvider.notifier).endSearch();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(libraryPrefsProvider);
    final notifier = ref.read(libraryPrefsProvider.notifier);
    final snapshot = ref.watch(librarySnapshotProvider(widget.folderId));
    final folderName = widget.folderId == null
        ? null
        : ref.watch(folderNameProvider(widget.folderId!)).value;

    final appBar = AppBar(
      title: prefs.searching
          ? _buildSearchField(notifier)
          : Text(folderName ?? 'Nanote'),
      bottom: _importing
          ? const PreferredSize(
              preferredSize: Size.fromHeight(2),
              child: LinearProgressIndicator(minHeight: 2),
            )
          : null,
      actions: [
        if (prefs.searching)
          IconButton(
            tooltip: 'Close search',
            icon: const Icon(Icons.close),
            onPressed: _endSearch,
          )
        else
          IconButton(
            tooltip: 'Search notes',
            icon: const Icon(Icons.search),
            onPressed: () {
              notifier.startSearch();
              _searchController.clear();
            },
          ),
        IconButton(
          tooltip: prefs.viewMode == LibraryViewMode.grid
              ? 'Switch to list'
              : 'Switch to grid',
          icon: Icon(
            prefs.viewMode == LibraryViewMode.grid
                ? Icons.view_list_outlined
                : Icons.grid_view_outlined,
          ),
          onPressed: () {
            final mode = prefs.viewMode == LibraryViewMode.grid
                ? LibraryViewMode.list
                : LibraryViewMode.grid;
            notifier.setViewMode(mode);
          },
        ),
        PopupMenuButton<LibrarySort>(
          tooltip: 'Sort',
          icon: const Icon(Icons.sort_outlined),
          initialValue: prefs.sort,
          onSelected: notifier.setSort,
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: LibrarySort.updated,
              checked: prefs.sort == LibrarySort.updated,
              child: const Text('Date modified'),
            ),
            CheckedPopupMenuItem(
              value: LibrarySort.name,
              checked: prefs.sort == LibrarySort.name,
              child: const Text('Name'),
            ),
          ],
        ),
      ],
    );

    return Scaffold(
      appBar: appBar,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateMenu,
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('Could not load the library:\n$e',
                textAlign: TextAlign.center),
          ),
        ),
        data: (snap) {
          if (prefs.searching) return _SearchResults(
            documents: snap.documents,
            viewMode: prefs.viewMode,
            onOpen: _openDocument,
            onActions: _documentActions,
            query: prefs.effectiveQuery ?? '',
          );
          if (snap.isEmpty) return _EmptyShelf(isRoot: widget.folderId == null);
          return LayoutBuilder(
            builder: (context, constraints) {
              final count =
                  (constraints.maxWidth / 230).clamp(2.0, 6.0).floor();
              final isGrid = prefs.viewMode == LibraryViewMode.grid;
              return CustomScrollView(
                slivers: [
                  if (snap.folders.isNotEmpty) ...[
                    _sectionHeader('Folders'),
                    _buildFolderSection(snap.folders, isGrid, count),
                  ],
                  if (snap.documents.isNotEmpty) ...[
                    _sectionHeader(
                      snap.folders.isEmpty ? 'Documents' : 'Notes',
                    ),
                    _buildDocumentSection(snap.documents, isGrid, count),
                  ],
                  const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSearchField(LibraryPrefs notifier) {
    return TextField(
      controller: _searchController,
      autofocus: true,
      textInputAction: TextInputAction.search,
      onChanged: notifier.setQuery,
      onSubmitted: (_) => FocusScope.of(context).unfocus(),
      decoration: const InputDecoration(
        hintText: 'Search all notes',
        border: InputBorder.none,
      ),
    );
  }

  static Widget _sectionHeader(String label) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }

  Widget _buildFolderSection(List<Folder> folders, bool isGrid, int count) {
    if (!isGrid) {
      return SliverList.builder(
        itemCount: folders.length,
        itemBuilder: (_, i) => FolderRow(
          folder: folders[i],
          onOpen: () => _openFolder(folders[i]),
          onLongPress: () => _folderActions(folders[i]),
        ),
      );
    }
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: folders.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FolderCard(
          folder: folders[i],
          onOpen: () => _openFolder(folders[i]),
          onLongPress: () => _folderActions(folders[i]),
        ),
      ),
    );
  }

  Widget _buildDocumentSection(List<Document> docs, bool isGrid, int count) {
    if (!isGrid) {
      return SliverList.builder(
        itemCount: docs.length,
        itemBuilder: (_, i) => DocumentRow(
          document: docs[i],
          onOpen: () => _openDocument(docs[i]),
          onLongPress: () => _documentActions(docs[i]),
        ),
      );
    }
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        // Thumb flexes (Expanded) + fixed ~48px meta block → safe at any width.
        childAspectRatio: 0.68,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: docs.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: DocumentCard(
          document: docs[i],
          onOpen: () => _openDocument(docs[i]),
          onLongPress: () => _documentActions(docs[i]),
        ),
      ),
    );
  }
}

/// Quick-find results — global (searching ignores the current folder), grid
/// or list, same cards as the shelf.
class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.documents,
    required this.viewMode,
    required this.onOpen,
    required this.onActions,
    required this.query,
  });

  final List<Document> documents;
  final LibraryViewMode viewMode;
  final ValueChanged<Document> onOpen;
  final ValueChanged<Document> onActions;
  final String query;

  @override
  Widget build(BuildContext context) {
    if (documents.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 56,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No notes matching “$query”'),
          ],
        ),
      );
    }
    final isGrid = viewMode == LibraryViewMode.grid;
    return CustomScrollView(
      slivers: [
        _HomeScreenState._sectionHeader(
          '${documents.length} ${documents.length == 1 ? 'result' : 'results'}',
        ),
        isGrid
            ? SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount:
                      (MediaQuery.sizeOf(context).width / 230).clamp(2.0, 6.0).floor(),
                  childAspectRatio: 0.68,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
                itemCount: documents.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: DocumentCard(
                    document: documents[i],
                    onOpen: () => onOpen(documents[i]),
                    onLongPress: () => onActions(documents[i]),
                  ),
                ),
              )
            : SliverList.builder(
                itemCount: documents.length,
                itemBuilder: (_, i) => DocumentRow(
                  document: documents[i],
                  onOpen: () => onOpen(documents[i]),
                  onLongPress: () => onActions(documents[i]),
                ),
              ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
      ],
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({required this.isRoot});

  final bool isRoot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.edit_note_outlined,
              size: 44,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            isRoot ? 'Your library is empty' : 'This folder is empty',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            isRoot
                ? 'Tap “New” to create a notebook or import a PDF.'
                : 'Add something with the “New” button.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
