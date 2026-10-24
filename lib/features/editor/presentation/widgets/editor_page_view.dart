import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/collections/document.dart';
import '../../../../core/database/collections/note_page.dart';
import '../../data/stroke_repository.dart';
import '../../domain/models/input_settings.dart';
import '../../domain/models/tools.dart';
import '../canvas/ink_canvas.dart';
import '../canvas/ink_controller.dart';
import '../canvas/input_policy.dart';
import '../canvas/selection_controller.dart';
import '../canvas/viewport_controller.dart';
import '../../../pdf/data/pdf_document_service.dart';
import '../../../pdf/presentation/pdf_layer.dart';

/// The controllers a hosting editor toolbar needs for ONE page.
class PageControllers {
  const PageControllers({
    required this.ink,
    required this.viewport,
    required this.selection,
  });

  final InkController ink;
  final ViewportController viewport;
  final SelectionController selection;
}

/// ONE page of ANY document — blank notebook or imported PDF — plus the
/// full drawing stack over it. The atomic building block the editor lays
/// out in its virtualized page scroller.
///
/// Lifecycle per page:
///  • creates its own [InkController] wired to the Stroke repository and
///    hydrates ONLY this page's ink (opening a 1000-page textbook loads one
///    page's strokes, never the whole book);
///  • PDFs additionally retain the shared, refcounted document handle —
///    many page views share ONE native parse; the last release closes it
///    and frees the tile cache;
///  • releases everything on unmount.
///
/// Use with `key: ValueKey(page.id)` so the widget recycles cleanly when
/// the host switches pages.
///
/// This replaces Step-4's PdfPageView: notebooks (pdfPath == null) get the
/// same controller stack minus the PDF layer, and paper template/shade now
/// resolve from per-page overrides falling back to document defaults.
class EditorPageView extends ConsumerStatefulWidget {
  const EditorPageView({
    super.key,
    required this.document,
    required this.page,
    required this.tool,
    this.onControllersReady,
  });

  final Document document;
  final NotePage page;
  final ToolPaletteState tool;
  final void Function(PageControllers controllers)? onControllersReady;

  @override
  ConsumerState<EditorPageView> createState() => _EditorPageViewState();
}

class _EditorPageViewState extends ConsumerState<EditorPageView> {
  InkController? _ink;
  ViewportController? _viewport;
  SelectionController? _selection;
  bool _fitted = false;
  bool _retained = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final persistence = await ref.read(strokeRepositoryProvider.future);
    if (_disposed) return;

    final ink = InkController(
      persistence: persistence,
      pageId: widget.page.id,
    );
    final viewport = ViewportController(
      pageWidth: widget.page.width,
      pageHeight: widget.page.height,
    );
    final selection = SelectionController(ink: ink, viewport: viewport);

    // PDF pages additionally hold the shared document handle.
    final pdfPath = widget.document.pdfPath;
    if (pdfPath != null) {
      await ref.read(pdfDocumentServiceProvider).retain(pdfPath);
      if (_disposed) {
        // Widget vanished between the await and the retain landing —
        // release the retain we just took (else it leaks forever), then
        // tear down and stop.
        await ref.read(pdfDocumentServiceProvider).release(pdfPath);
        selection.dispose();
        ink.dispose();
        viewport.dispose();
        return;
      }
      _retained = true;
    }

    await ink.hydrate();
    if (_disposed) {
      if (_retained) {
        await ref.read(pdfDocumentServiceProvider).release(pdfPath!);
      }
      selection.dispose();
      ink.dispose();
      viewport.dispose();
      return;
    }

    _ink = ink;
    _viewport = viewport;
    _selection = selection;
    if (mounted) setState(() {});
    widget.onControllersReady?.call(
      PageControllers(ink: ink, viewport: viewport, selection: selection),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    final pdfPath = widget.document.pdfPath;
    if (pdfPath != null && _retained) {
      // Unawaited on purpose — release must not block teardown.
      ref.read(pdfDocumentServiceProvider).release(pdfPath);
    }
    _selection?.dispose();
    _ink?.dispose();
    _viewport?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = _ink;
    final viewport = _viewport;
    final selection = _selection;
    if (ink == null || viewport == null || selection == null) {
      return const SizedBox.expand(); // Isar (+ PDF handle) still opening
    }

    final input = ref.watch(inputSettingsProvider);
    final doc = widget.document;
    final page = widget.page;
    final pdfPath = doc.pdfPath;

    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      if (!_fitted && size != Size.zero) {
        _fitted = true;
        viewport.canvasSize = size;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => viewport.fitToPage(size, margin: 16),
        );
      } else if (size != Size.zero && viewport.canvasSize != size) {
        viewport.canvasSize = size; // for the editor's fit button
      }
      return InkCanvas(
        controller: ink,
        viewport: viewport,
        tool: widget.tool,
        selection: selection,
        policy: PalmRejectionPolicy(
          enabled: input.palmRejection,
          allowFingerDrawing: input.allowFingerDrawing,
        ),
        paperTemplate: page.templateOverride ?? doc.paperTemplate,
        paperShade: page.shadeOverride ?? doc.paperShade,
        pdfLayer: pdfPath == null
            ? null
            : PdfLayer(
                pdfPath: pdfPath,
                pageNumber: page.pdfPageNumber ?? 1,
                pageSize: Size(page.width, page.height),
                viewport: viewport,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              ),
        overlayAccentColor: Theme.of(context).colorScheme.primary,
      );
    });
  }
}
