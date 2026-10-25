import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../core/database/collections/document.dart';
import '../../../../core/database/collections/note_page.dart';
import '../../../library/data/library_providers.dart';
import '../../../library/data/library_repository.dart';
import '../../../pdf/data/pdf_tile_cache.dart';
import '../../data/export_service.dart';
import '../../data/stroke_repository.dart';
import '../../data/text_repository.dart';
import '../../domain/models/input_settings.dart';
import '../../domain/models/tools.dart';
import '../canvas/navigation_shield.dart';
import '../widgets/editor_chrome.dart';
import '../widgets/editor_page_view.dart';
import '../widgets/page_thumbnails_panel.dart';

/// The document editor: a virtualized vertical PageView of [EditorPageView]
/// pages + the Notewise-style floating chrome (nav pill / tool pill /
/// contextual sub-pill / page badge / edge arrows / thumbnails rail).
///
/// Input ownership (v1.1 — the dual-gesture fix, kept intact):
///  • STYLUS / MOUSE write — they are excluded from the pager's drag
///    devices, so a pen stroke can never also scroll or flip pages;
///  • a LONE FINGER navigates (native PageView drag with spring physics)
///    — EXCEPT while the hand tool is selected or finger-inking is enabled,
///    when the pager admits NO drag device at all (see [_dragDevicesFor]);
///  • TWO FINGERS pinch/pan the page inside its canvas — for the duration
///    every page's router raises [NavigationShield], which freezes the
///    pager (killing any in-flight drag) and settles to the nearest page
///    when the gesture ends;
///  • the HAND tool freezes the pager from the moment it is selected (the
///    shield is raised on tool change — zero gesture race): its finger
///    pans the canvas, never the pages;
///  • palm touches are ignored outright (policy) or rest inert (router),
///    and the shield keeps them from flipping pages while the pen works.
///
/// Persistence needs NO save button: each page's InkController owns a
/// serialized DB queue that flushes stroke edits as they happen. On close
/// we only bump the document's `updatedAt` if ink actually changed.
class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key, required this.documentId});

  final int documentId;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  /// Floating chrome reserves — the initial page fit keeps fresh content
  /// clear of the top pills and the bottom page badge.
  static const double _topChromeReserve = 128;
  static const double _bottomChromeReserve = 76;

  /// iOS-feel page snapping on every platform: bouncy edges + a spring
  /// settle (the Android default clamp is what made turns feel mechanical).
  static const _kPagePhysics = PageScrollPhysics(parent: BouncingScrollPhysics());

  PageController? _pageController;
  int _pageIndex = 0;

  /// Page id → controllers of every currently-mounted page (visible ± 1).
  final Map<int, PageControllers> _controllersByPage = {};

  /// True once the session actually changed ink (drives updatedAt bump).
  bool _edited = false;

  /// OR-merge of every mounted page's "freeze the pager" demand.
  late final NavigationShield _shield = NavigationShield();
  bool _shieldActive = false;

  /// Chrome visibility.
  bool _readMode = false;
  bool _thumbsOpen = false;

  /// Export progress (ValueNotifier → no editor rebuilds per page).
  final ValueNotifier<double?> _exportProgress = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _shield.addListener(_onShieldChanged);
    // XNota parity: the screen stays awake while a note is open for ink.
    WakelockPlus.enable();
  }

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
    _shield.removeListener(_onShieldChanged);
    _shield.dispose();
    _pageController?.dispose();
    _exportProgress.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ── Navigation shield ────────────────────────────────────────────────────

  void _onShieldChanged() {
    final active = _shield.active;
    final wasActive = _shieldActive;
    _shieldActive = active;
    if (!mounted) return;
    // Swap the pager's physics (only fires on global on/off edges).
    setState(() {});
    if (wasActive && !active) {
      // A page turn was aborted mid-flight (pen contact / pinch upgrade) —
      // settle to the nearest page AFTER the physics swap rebuild lands,
      // so the animation runs under the real page physics.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _snapToNearestPage();
      });
    }
  }

  void _snapToNearestPage() {
    final controller = _pageController;
    if (controller == null || !controller.hasClients) return;
    final page = controller.page;
    if (page == null) return;
    if ((page - page.roundToDouble()).abs() < 0.001) return; // already aligned
    controller.animateToPage(
      page.round(),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  // ── Page bookkeeping ─────────────────────────────────────────────────────

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
    controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
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

  // ── Zoom actions (operate on the CURRENT page's viewport) ────────────────

  // ── Offline export (XNota parity) ───────────────────────────────────

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _exportPdf(Document doc, List<NotePage> pages) async {
    if (_exportProgress.value != null) return; // already exporting
    _exportProgress.value = 0.0;
    try {
      final strokesRepo = await ref.read(strokeRepositoryProvider.future);
      final textRepo = await ref.read(textRepositoryProvider.future);
      final export = ExportService(ref.read(pdfDocumentServiceProvider));
      final path = await export.exportDocumentPdf(
        document: doc,
        pages: pages,
        strokesFor: (p) => strokesRepo.loadStrokes(p.id),
        textFor: (p) => textRepo.loadBlocks(p.id),
        onProgress: (done, total) => _exportProgress.value = done / total,
      );
      _exportProgress.value = null;
      if (path == null) {
        _showSnack('Export canceled');
      } else {
        _showSnack('PDF saved');
      }
    } catch (e) {
      _exportProgress.value = null;
      _showSnack('Export failed: $e');
    }
  }

  Future<void> _exportPng(Document doc, NotePage page) async {
    final c = _controllersByPage[page.id];
    if (c == null) {
      _showSnack('The page is still loading — try again in a moment');
      return;
    }
    try {
      final export = ExportService(ref.read(pdfDocumentServiceProvider));
      final path = await export.exportPagePng(
        document: doc,
        page: page,
        strokes: List.of(c.ink.strokes),
        textBlocks: List.of(c.text.blocks),
      );
      if (mounted && path != null) _showSnack('PNG saved');
    } catch (e) {
      _showSnack('Export failed: $e');
    }
  }

  PageControllers? get _currentControllers {
    final doc = ref.read(libraryDocumentProvider(widget.documentId)).value;
    final pages =
        ref.read(documentPagesProvider(widget.documentId)).value ?? const [];
    if (pages.isEmpty) return null;
    final page = pages[_pageIndex.clamp(0, pages.length - 1)];
    return _controllersByPage[page.id];
  }

  Size? get _canvasSize => _currentControllers?.viewport.canvasSize;

  void _fitPage() {
    final c = _currentControllers;
    final size = _canvasSize;
    if (c == null || size == null || size == Size.zero) return;
    c.viewport.fitToPage(
      Size(size.width,
          size.height - _topChromeReserve - _bottomChromeReserve),
      margin: 16,
      centerBias: const Offset(0, _topChromeReserve),
    );
  }

  void _fitWidth() {
    final c = _currentControllers;
    final size = _canvasSize;
    if (c == null || size == null || size == Size.zero) return;
    c.viewport.fitToWidth(size, margin: 24);
  }

  void _setZoom(double target) {
    final c = _currentControllers;
    final size = _canvasSize;
    if (c == null || size == null || size == Size.zero) return;
    c.viewport.setZoom(target, size);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final docAsync = ref.watch(libraryDocumentProvider(widget.documentId));
    final pagesAsync = ref.watch(documentPagesProvider(widget.documentId));
    final tool = ref.watch(toolPaletteProvider);
    final input = ref.watch(inputSettingsProvider);

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

        return ScrollConfiguration(
          behavior: _EditorScrollBehavior(_dragDevicesFor(tool, input)),
          child: PageView.builder(
            controller: _pageController,
            physics: _shieldActive
                ? const NeverScrollableScrollPhysics()
                : _kPagePhysics,
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
              navigationShield: _shield,
              fitTopInset: _topChromeReserve,
              fitBottomInset: _bottomChromeReserve,
              onControllersReady: (c) => _onControllersReady(pages[i], c),
            ),
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

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      // No AppBar — the whole editor is floating Notewise chrome over a
      // full-bleed canvas (see the Stack below).
      body: ColoredBox(
        // Workspace color — pages float on it (BackdropPainter adds the
        // shadow); doubles as the loading/empty-state background.
        color: isDark ? const Color(0xFF0D1117) : const Color(0xFFE8EAF1),
        child: Stack(
          children: [
            Positioned.fill(child: scaffoldBody),

            // ── Export progress pill (top center) ─────────────────────
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SafeArea(
                    child: ValueListenableBuilder<double?>(
                      valueListenable: _exportProgress,
                      builder: (context, v, _) {
                        if (v == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: kChromePillColor,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: const [kChromeShadow],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  'Exporting… ${(v * 100).round()}%',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),

            // ── Thumbnails rail + scrim ────────────────────────────────
            if (doc != null && pages.isNotEmpty) ...[
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_thumbsOpen,
                  child: AnimatedOpacity(
                    opacity: _thumbsOpen ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _thumbsOpen = false),
                      child: const ColoredBox(
                        color: Color(0x42000000),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                right: null,
                child: AnimatedSlide(
                  offset: _thumbsOpen ? Offset.zero : const Offset(-1, 0),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: SafeArea(
                    child: PageThumbnailsPanel(
                      document: doc,
                      pages: pages,
                      currentIndex:
                          _pageIndex.clamp(0, pages.length - 1),
                      onSelect: (i) {
                        setState(() => _thumbsOpen = false);
                        _goToPage(i, pages.length);
                      },
                    ),
                  ),
                ),
              ),
            ],

            // ── Top chrome (nav pill · tool pill · context pill · eye) ──
            if (!_readMode)
              Positioned(
                left: 12,
                top: 0,
                right: 12,
                child: SafeArea(
                  bottom: false,
                  child: EditorTopChrome(
                    controllers: controllers,
                    onBack: () => Navigator.of(context).maybePop(),
                    onThumbnails: () =>
                        setState(() => _thumbsOpen = !_thumbsOpen),
                    onAddPage:
                        (doc != null && doc.type == DocumentType.notebook)
                            ? () => _addPage(doc, pages.length)
                            : null,
                    onToggleReadMode: () => setState(() => _readMode = true),
                    onOpenSettings: () => showTouchSettingsSheet(context),
                    onExportPdf: (doc != null && pages.isNotEmpty)
                        ? () => _exportPdf(doc, pages)
                        : null,
                    onExportPng: (doc != null && currentPage != null)
                        ? () => _exportPng(doc, currentPage!)
                        : null,
                  ),
                ),
              )
            else
              Positioned(
                top: 12,
                right: 12,
                child: SafeArea(
                  bottom: false,
                  child: ReadModeExitPill(
                    onExit: () => setState(() => _readMode = false),
                  ),
                ),
              ),

            // ── Page badge (bottom-left, Notewise "28 / 28 | 233%") ────
            if (!_readMode)
              Positioned(
                left: 12,
                bottom: 12,
                child: SafeArea(
                  top: false,
                  child: EditorPageBadge(
                    controllers: controllers,
                    index: _pageIndex.clamp(0, pages.isEmpty ? 0 : pages.length - 1),
                    count: pages.isEmpty ? 1 : pages.length,
                    onPrev: () => _goToPage(
                      _pageIndex.clamp(0, pages.length - 1) - 1,
                      pages.length,
                    ),
                    onNext: () => _goToPage(
                      _pageIndex.clamp(0, pages.length - 1) + 1,
                      pages.length,
                    ),
                    onJump: () => _showJumpDialog(pages.length),
                    onFitPage: _fitPage,
                    onFitWidth: _fitWidth,
                    onZoom100: () => _setZoom(1.0),
                    onZoomIn: () => _setZoom(
                        (controllers?.viewport.scale ?? 1.0) * 1.25),
                    onZoomOut: () => _setZoom(
                        (controllers?.viewport.scale ?? 1.0) / 1.25),
                  ),
                ),
              ),

            // ── Right-edge page arrows ─────────────────────────────────
            if (!_readMode)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: SafeArea(
                    child: EditorEdgeNav(
                      index: _pageIndex.clamp(0, pages.isEmpty ? 0 : pages.length - 1),
                      count: pages.length,
                      onPrev: () => _goToPage(
                        _pageIndex.clamp(0, pages.length - 1) - 1,
                        pages.length,
                      ),
                      onNext: () => _goToPage(
                        _pageIndex.clamp(0, pages.length - 1) + 1,
                        pages.length,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Which pointer devices may drive the pager:
  ///
  ///  • normally, TOUCH ONLY (stylus/mouse are ink pointers);
  ///  • NOTHING while the hand tool is selected (its finger pans the
  ///    canvas) or while finger-inking is enabled (a drawing finger must
  ///    never also scroll pages) — the router owns those touches instead.
  Set<PointerDeviceKind> _dragDevicesFor(
    ToolPaletteState tool,
    InputSettingsState input,
  ) {
    if (tool.tool == ToolType.hand || input.allowFingerDrawing) {
      return const <PointerDeviceKind>{};
    }
    return const <PointerDeviceKind>{PointerDeviceKind.touch};
  }
}

/// Fingers (usually) drive the pager. Stylus and mouse pointers are INK
/// pointers — admitting them here is exactly what made a pen stroke scroll
/// the page it was writing on. (Trackpads still scroll via their native
/// events.) While the hand tool / finger-inking owns touch, NO device can
/// drag the pager — see [_EditorScreenState._dragDevicesFor].
class _EditorScrollBehavior extends ScrollBehavior {
  const _EditorScrollBehavior(this.dragDevices);

  @override
  final Set<PointerDeviceKind> dragDevices;

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child; // no scrollbar over the reading surface
}
