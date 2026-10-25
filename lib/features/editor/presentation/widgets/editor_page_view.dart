import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/collections/document.dart';
import '../../../../core/database/collections/note_page.dart';
import '../../data/stroke_repository.dart';
import '../../data/text_repository.dart';
import '../../domain/models/input_settings.dart';
import '../../domain/models/tools.dart';
import '../canvas/ink_canvas.dart';
import '../canvas/ink_controller.dart';
import '../canvas/input_policy.dart';
import '../canvas/navigation_shield.dart';
import '../canvas/painters/text_block_painter.dart';
import '../canvas/selection_controller.dart';
import '../canvas/text_layer_controller.dart';
import '../canvas/viewport_controller.dart';
import '../../../pdf/data/pdf_document_service.dart';
import '../../../pdf/presentation/pdf_layer.dart';
import 'text_block_editor_sheet.dart';

/// The controllers a hosting editor toolbar needs for ONE page.
class PageControllers {
  const PageControllers({
    required this.ink,
    required this.viewport,
    required this.selection,
    required this.text,
  });

  final InkController ink;
  final ViewportController viewport;
  final SelectionController selection;
  final TextLayerController text;
}

/// ONE page of ANY document — blank notebook or imported PDF — plus the
/// full drawing stack over it. The atomic building block the editor lays
/// out in its virtualized page scroller.
///
/// Lifecycle per page:
///  • creates its own [InkController] wired to the Stroke repository (and
///    a [TextLayerController] wired to the TextBlock repository) and
///    hydrates ONLY this page's content — opening a 1000-page textbook
///    loads one page, never the whole book);
///  • PDFs additionally retain the shared, refcounted document handle —
///    many page views share ONE native parse; the last release closes it
///    and frees the tile cache;
///  • releases everything on unmount.
///
/// Use with `key: ValueKey(page.id)` so the widget recycles cleanly when
/// the host switches pages.
class EditorPageView extends ConsumerStatefulWidget {
  const EditorPageView({
    super.key,
    required this.document,
    required this.page,
    required this.tool,
    this.onControllersReady,
    this.navigationShield,
    this.fitBottomInset = 0,
    this.fitTopInset = 0,
  });

  final Document document;
  final NotePage page;
  final ToolPaletteState tool;
  final void Function(PageControllers controllers)? onControllersReady;

  /// Shared pager-freeze channel — see [NavigationShield]. The hosting
  /// editor owns the instance so every mounted page ORs into the same bit.
  final NavigationShield? navigationShield;

  /// Height (screen px) the initial fit must leave free below/above the
  /// page so the floating chrome never covers freshly-opened content.
  final double fitBottomInset;
  final double fitTopInset;

  @override
  ConsumerState<EditorPageView> createState() => _EditorPageViewState();
}

class _EditorPageViewState extends ConsumerState<EditorPageView> {
  InkController? _ink;
  ViewportController? _viewport;
  SelectionController? _selection;
  TextLayerController? _text;
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

    final textPersistence = await ref.read(textRepositoryProvider.future);
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
    final text = TextLayerController(
      persistence: textPersistence,
      pageId: widget.page.id,
    );

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
        text.dispose();
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
      text.dispose();
      ink.dispose();
      viewport.dispose();
      return;
    }
    await text.hydrate();
    if (_disposed) {
      if (_retained) {
        await ref.read(pdfDocumentServiceProvider).release(pdfPath!);
      }
      selection.dispose();
      text.dispose();
      ink.dispose();
      viewport.dispose();
      return;
    }

    _ink = ink;
    _viewport = viewport;
    _selection = selection;
    _text = text;
    if (mounted) setState(() {});
    widget.onControllersReady?.call(
      PageControllers(
          ink: ink, viewport: viewport, selection: selection, text: text),
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
    _text?.dispose();
    _ink?.dispose();
    _viewport?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = _ink;
    final viewport = _viewport;
    final selection = _selection;
    final text = _text;
    if (ink == null ||
        viewport == null ||
        selection == null ||
        text == null) {
      return const SizedBox.expand(); // Isar (+ PDF handle) still opening
    }

    final input = ref.watch(inputSettingsProvider);
    final doc = widget.document;
    final page = widget.page;
    final pdfPath = doc.pdfPath;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tool = widget.tool;

    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      if (!_fitted && size != Size.zero) {
        _fitted = true;
        viewport.canvasSize = size;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => viewport.fitToPage(
            Size(size.width,
                size.height - widget.fitTopInset - widget.fitBottomInset),
            margin: 16,
            // Shift the fitted box DOWN so the page sits centered in the
            // free area BETWEEN the top pills and the bottom badge (the
            // box itself starts at the canvas top edge).
            centerBias: Offset(0, widget.fitTopInset),
          ),
        );
      } else if (size != Size.zero && viewport.canvasSize != size) {
        viewport.canvasSize = size; // for the editor's fit button
      }
      return InkCanvas(
        controller: ink,
        viewport: viewport,
        tool: tool,
        selection: selection,
        text: text,
        policy: PalmRejectionPolicy(
          enabled: input.palmRejection,
          allowFingerDrawing: input.allowFingerDrawing,
        ),
        navigationShield: widget.navigationShield,
        backdropColor: isDark
            ? const Color(0xFF0D1117)
            : const Color(0xFFE8EAF1),
        pageShadowColor:
            isDark ? Colors.black.withOpacity(0.55) : const Color(0x29434653),
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
        textLayer: CustomPaint(
          painter: TextBlockPainter(controller: text, viewport: viewport),
          child: const SizedBox.expand(),
        ),
        onCreateText: (pagePoint) {
          if (!mounted) return;
          showTextBlockEditorSheet(
            context,
            controller: text,
            createAt: pagePoint,
            defaultSize: tool.textSize,
            defaultColor: tool.textColor,
            stickyDefault: tool.textSticky,
            stickyColorDefault: tool.stickyColor,
          );
        },
        onEditText: (block) {
          if (!mounted) return;
          showTextBlockEditorSheet(
            context,
            controller: text,
            editing: block,
            defaultSize: tool.textSize,
            defaultColor: tool.textColor,
            stickyDefault: tool.textSticky,
            stickyColorDefault: tool.stickyColor,
          );
        },
        overlayAccentColor: Theme.of(context).colorScheme.primary,
      );
    });
  }
}
