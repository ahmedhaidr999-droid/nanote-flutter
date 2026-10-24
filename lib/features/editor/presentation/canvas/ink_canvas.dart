import 'package:flutter/material.dart';

import '../../../../core/database/collections/document.dart';
import '../../domain/models/tools.dart';
import 'ink_controller.dart';
import 'input_policy.dart';
import 'input_router.dart';
import 'navigation_shield.dart';
import 'painters/backdrop_painter.dart';
import 'painters/ink_painter.dart';
import 'painters/paper_painter.dart';
import 'painters/selection_overlay_painter.dart';
import 'selection_controller.dart';
import 'viewport_controller.dart';

/// The layered drawing surface:
///
///     raw-pointer Listener
///       └─ paper CustomPaint          (PaperPainter)
///       └─ pdfLayer widget slot        (PdfLayer — Step 4; same viewport)
///       └─ ink CustomPaint             (InkPainter)
///       └─ selection CustomPaint       (SelectionOverlayPainter)
///
/// All layers share ONE [ViewportController] — a single source of truth for
/// the page↔screen transform. That (not event "syncing") is what keeps ink
/// and PDF pixels perfectly aligned at any zoom.
///
/// The selection layer is optional: without a [SelectionController] the
/// lasso tool is a no-op and the canvas behaves exactly like Step 2.
class InkCanvas extends StatefulWidget {
  const InkCanvas({
    super.key,
    required this.controller,
    required this.viewport,
    required this.tool,
    this.selection,
    this.pdfLayer,
    this.paperTemplate = PaperTemplate.ruled,
    this.paperShade = PaperShade.light,
    this.policy,
    this.overlayAccentColor = const Color(0xFF155EEF),
    this.navigationShield,
    this.backdropColor = const Color(0xFFE8EAF1),
    this.pageShadowColor = const Color(0x29434653),
  });

  final InkController controller;
  final ViewportController viewport;
  final ToolPaletteState tool;
  final SelectionController? selection;

  /// PDF raster layer (Step 4). Must remain a raw CustomPaint sibling —
  /// see [PdfLayer]'s compositing notes — hence an opaque widget slot.
  final Widget? pdfLayer;

  final PaperTemplate paperTemplate;
  final PaperShade paperShade;
  final InputPolicy? policy;
  final Color overlayAccentColor;

  /// Shared "freeze the page pager" channel — the router reports active
  /// gestures / stylus-in-range here (see [NavigationShield]).
  final NavigationShield? navigationShield;

  /// Workspace color around the page + the page's drop-shadow color
  /// (Notewise/GoodNotes floating-page look).
  final Color backdropColor;
  final Color pageShadowColor;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> {
  late final InputRouter _router;

  @override
  void initState() {
    super.initState();
    _router = InputRouter(
      ink: widget.controller,
      viewport: widget.viewport,
      selection: widget.selection,
      policy: widget.policy ?? const PalmRejectionPolicy(),
    );
    _router.navigationShield = widget.navigationShield;
  }

  @override
  void dispose() {
    // Cancels the router's hover timer and releases its shield entry so a
    // disposed neighbor page can never keep the pager frozen.
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Cold-state refresh — a plain field write, no router churn.
    _router.tool = widget.tool;
    if (widget.policy != null) _router.policy = widget.policy!;

    return Listener(
      // Opaque: the canvas must receive every pointer, even over blank
      // areas where no child would claim the hit.
      behavior: HitTestBehavior.opaque,
      onPointerDown: _router.onPointerDown,
      onPointerMove: _router.onPointerMove,
      onPointerUp: _router.onPointerUp,
      onPointerCancel: _router.onPointerCancel,
      onPointerSignal: _router.onPointerSignal,
      // Stylus proximity (palm-rejection signal) + trackpad gestures.
      onPointerHover: _router.onPointerHover,
      onPointerPanZoomStart: _router.onPointerPanZoomStart,
      onPointerPanZoomUpdate: _router.onPointerPanZoomUpdate,
      onPointerPanZoomEnd: _router.onPointerPanZoomEnd,
      child: Stack(
        children: [
          CustomPaint(
            // Workspace backdrop + floating-page shadow (below everything).
            painter: BackdropPainter(
              backdropColor: widget.backdropColor,
              shadowColor: widget.pageShadowColor,
              pageSize: Size(
                  widget.viewport.pageWidth, widget.viewport.pageHeight),
              viewport: widget.viewport,
            ),
            child: const SizedBox.expand(),
          ),
          CustomPaint(
            painter: PaperPainter(
              template: widget.paperTemplate,
              shade: widget.paperShade,
              pageSize: Size(widget.viewport.pageWidth, widget.viewport.pageHeight),
              viewport: widget.viewport,
            ),
            child: const SizedBox.expand(),
          ),
          if (widget.pdfLayer != null) widget.pdfLayer!,
          CustomPaint(
            painter: InkPainter(
              controller: widget.controller,
              viewport: widget.viewport,
              selection: widget.selection,
            ),
            child: const SizedBox.expand(),
          ),
          if (widget.selection != null)
            CustomPaint(
              painter: SelectionOverlayPainter(
                selection: widget.selection!,
                ink: widget.controller,
                viewport: widget.viewport,
                accentColor: widget.overlayAccentColor,
              ),
              child: const SizedBox.expand(),
            ),
        ],
      ),
    );
  }
}
