import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/collections/document.dart';
import '../../../../core/database/collections/note_page.dart';
import '../../../library/data/library_providers.dart';
import '../../../library/data/library_repository.dart';
import '../../../pdf/data/pdf_tile_cache.dart';
import '../../domain/models/tools.dart';
import '../widgets/editor_page_view.dart';
import '../widgets/editor_toolbar.dart';

/// The document editor: a virtualized vertical PageView of [EditorPageView]
/// pages + chrome (app bar with undo/redo, bottom toolbar with tools, page
/// scrubber and selection actions).
///
/// Virtualization: PageView keeps only the visible page + neighbors alive
/// (`allowImplicitScrolling`) — every other page's ink, PDF raster and
/// controllers simply do not exist while off-screen. Undo state persists
/// for the current page and its neighbors because their widgets stay
/// mounted; beyond that, undo history intentionally resets (per-page undo,
/// GoodNotes behaviour).
///
/// Persistence needs NO save button: each page's InkController owns a
/// serialized DB queue (Step 2) that flushes stroke edits as they happen.
/// On close we only bump the document's `updatedAt` if ink actually changed.
class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key, required this.documentId});

  final int documentId;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  PageController? _pageController;
  int _pageIndex = 0;

  /// Page id → controllers of every currently-mounted page (visible ± 1).
  final Map<int, PageControllers> _controllersByPage = {};

  /// True once the session actually changed ink (drives updatedAt bump).
  bool _edited = false;

  @override
  void dispose() {
    // Capture the repo future BEFORE super.dispose() invalidates `ref`.
    final repoFuture = ref.read(libraryRepositoryProvider.future);
    if (_edited) {
      final documentId = widget.documentId;
      unawaited(
        repoFuture.then((repo) => repo.touchDocument(documentId)),
      );
    }
    _pageController?.dispose();
    super.dispose();
  }

  void Function() _inkListenerFor(PageControllers controllers) {
    return () {
      if (controllers.ink.canUndo) _edited = true;
    };
  }

  void _onControllersReady(NotePage page, PageControllers controllers) {
    if (!mounted) return;
    // Neighbors pre-mount too — only remember pages we may show soon;
    // stale entries for disposed pages are pruned on page change.
    _controllersByPage[page.id] = controllers;
    controllers.ink.addListener(_inkListenerFor(controllers));
    if (mounted && page.index == _pageIndex) setState(() {});
  }

  void _onPageChanged(int index, List<NotePage> pages) {
    setState(() => _pageIndex = index);
    // Prune controller entries for pages that left the ±1 window — their
    // widgets are gone; keeping refs would pin disposed InkControllers
    // (and their stroke lists) in memory.
    _controllersByPage.removeWhere((id, _) {
      for (final delta in const [-1, 0, 1]) {
        final i = index + delta;
        if (i >= 0 && i < pages.length && pages[i].id == id) return false;
      }
      return true;
    });
  }

  /// Warms the neighbors' PDF rasters at reading scale — swipe-feels-instant
  /// virtualization across even 1000-page documents.
  void _prefetchNeighbors(Document doc, List<NotePage> pages, int index) {
    final pdfPath = doc.pdfPath;
    if (pdfPath == null) return;
    final cache = ref.read(pdfTileCacheProvider);
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
    for (final delta in const [-1, 1]) {
      final n = index + delta;
      if (n >= 0 && n < pages.length) {
        cache.prefetch(pdfPath, pages[n].pdfPageNumber ?? (n + 1), dpr);
      }
    }
  }

  void _goToPage(int index, int count) {
    final controller = _pageController;
    if (controller == null || index < 0 || index >= count) return;
    final duration = const Duration(milliseconds: 250);
    const curve = Curves.easeOutCubic;
    controller.animateToPage(
      index,
      duration: duration,
      curve: curve,
    );
  }

  Future<void> _addPage(Document doc, int currentCount) async {
    final repo = await ref.read(libraryRepositoryProvider.future);
    final next = await repo.appendPage(doc);
    if (next != null) _goToPage(next, currentCount + 1);
  }

  Future<void> _showJumpDialog(int count) {
    final controller = TextEditingController(
      text: '${_pageIndex + 1}',
    );
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            suffixText: 'of $count',
          ),
          onSubmitted: (value) {
            final n = int.tryParse(value.trim());
            Navigator.of(dialogContext).pop();
            if (n != null) _goToPage(n - 1, count);
          },
        ),
        actions: [
          TextButton(
            onPressed: Navigator.of(dialogContext).pop,
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(controller.text.trim());
              Navigator.of(dialogContext).pop();
              if (n != null) _goToPage(n - 1, count);
            },
            child: const Text('Go'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final docAsync = ref.watch(libraryDocumentProvider(widget.documentId));
    final pagesAsync = ref.watch(documentPagesProvider(widget.documentId));
    final tool = ref.watch(toolPaletteProvider);

    final doc = docAsync.value;
    final pages = pagesAsync.value ?? const <NotePage>[];

    // Initialize the PageController once the first pages stream in.
    if (_pageController == null && pages.isNotEmpty) {
      _pageController = PageController(initialPage: 0);
    }

    final scaffoldBody = Builder(
      builder: (context) {
        if (docAsync.isLoading || pagesAsync.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (doc == null) {
          // Deleted mid-session (not reachable from our own UI, but stay
          // correct anyway) or bad deep link.
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('This document is no longer available.'),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Back'),
                ),
              ],
            ),
          );
        }
        if (pages.isEmpty) {
          return const Center(child: Text('This document has no pages.'));
        }

        // Keep index valid when pages shrink (only possible via other
        // surfaces for now, but cheap to guard).
        final safeIndex = _pageIndex.clamp(0, pages.length - 1);
        if (safeIndex != _pageIndex) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _pageController?.jumpToPage(safeIndex),
          );
        }

        return PageView.builder(
          controller: _pageController,
          scrollDirection: Axis.vertical,
          // Pre-mounts ±1 neighbors: instant swipes, live undo state for
          // adjacent pages, PDF prefetch — at bounded memory cost.
          allowImplicitScrolling: true,
          itemCount: pages.length,
          onPageChanged: (i) {
            _onPageChanged(i, pages);
            _prefetchNeighbors(doc, pages, i);
          },
          itemBuilder: (context, i) => EditorPageView(
            key: ValueKey(pages[i].id),
            document: doc,
            page: pages[i],
            tool: tool,
            onControllersReady: (c) => _onControllersReady(pages[i], c),
          ),
        );
      },
    );

    final currentPage = pages.isEmpty
        ? null
        : pages[_pageIndex.clamp(0, pages.length - 1)];
    final controllers = currentPage == null
        ? null
        : _controllersByPage[currentPage.id];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          doc?.title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          _UndoRedoButtons(controllers: controllers),
          if (pages.length > 1)
            IconButton(
              tooltip: 'Go to page…',
              icon: const Icon(Icons.menu_book_outlined),
              onPressed: () => _showJumpDialog(pages.length),
            ),
        ],
      ),
      body: scaffoldBody,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          elevation: 0,
          child: EditorToolbar(
            controllers: controllers,
            isPdf: doc?.type == DocumentType.pdf,
            onFit: () {
              final c = controllers;
              if (c == null) return;
              // Fits the VISIBLE canvas (app bar + toolbar excluded) —
              // EditorPageView records the exact laid-out size.
              final size = c.viewport.canvasSize;
              if (size != null && size != Size.zero) {
                c.viewport.fitToPage(size, margin: 24);
              }
            },
            onAddPage:
                doc == null ? null : () => _addPage(doc, pages.length),
            pageIndex:
                pages.isEmpty ? 0 : _pageIndex.clamp(0, pages.length - 1),
            pageCount: pages.length,
            onPageSelected: (i) => _goToPage(i, pages.length),
          ),
        ),
      ),
    );
  }
}

/// Undo/redo for the CURRENT page only, live via AnimatedBuilder on the
/// page's InkController (no widget rebuilds from the 120Hz ink stream).
class _UndoRedoButtons extends StatelessWidget {
  const _UndoRedoButtons({required this.controllers});

  final PageControllers? controllers;

  @override
  Widget build(BuildContext context) {
    final ink = controllers?.ink;
    if (ink == null) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(onPressed: null, icon: Icon(Icons.undo_outlined)),
          IconButton(onPressed: null, icon: Icon(Icons.redo_outlined)),
        ],
      );
    }
    return AnimatedBuilder(
      animation: ink,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Undo',
            onPressed: ink.canUndo ? ink.undo : null,
            icon: const Icon(Icons.undo_outlined),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: ink.canRedo ? ink.redo : null,
            icon: const Icon(Icons.redo_outlined),
          ),
        ],
      ),
    );
  }
}
