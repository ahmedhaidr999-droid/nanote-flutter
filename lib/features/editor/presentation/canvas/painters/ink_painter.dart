import 'package:flutter/material.dart';

import '../../../../../core/database/collections/stroke.dart';
import '../../../domain/geometry/ink_geometry.dart';
import '../ink_controller.dart';
import '../selection_controller.dart';
import '../viewport_controller.dart';

/// Renders committed ink (cached outlines) plus the live stroke — in PAGE
/// space, inside the shared viewport transform.
///
/// Repaint triggers: `repaint: controller ∪ viewport ∪ selection` — a
/// stroke edit, a pan/zoom or a selection change repaint; nothing else
/// does. No widget rebuilds involved.
///
/// Culling: strokes outside the visible page rect are skipped via their
/// denormalized bbox — scrolling a 10k-stroke page stays cheap.
///
/// While a lasso transform is active, strokes in the selection are
/// SUPPRESSED here — [SelectionOverlayPainter] draws them transformed, so
/// the ink visibly follows the gesture without mutating any committed row.
class InkPainter extends CustomPainter {
  InkPainter({required this.controller, required this.viewport, this.selection})
      : super(repaint: Listenable.merge([
          controller,
          viewport,
          if (selection != null) selection,
        ]));

  final InkController controller;
  final ViewportController viewport;
  final SelectionController? selection;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.transform(viewport.matrix.storage);

    final visible = viewport.visiblePageRect(size).inflate(64);
    final sel = selection;
    final transforming = sel != null && sel.isTransforming;

    for (final s in controller.strokes) {
      if (transforming && sel.isSelected(s)) continue; // previewed by overlay

      if (s.maxX < visible.left || s.minX > visible.right) continue;
      if (s.maxY < visible.top || s.minY > visible.bottom) continue;

      final o = controller.outlineOf(s);
      final paint = paintFor(s.tool, s.colorValue);
      canvas.drawPath(o.body, paint);
      if (o.startRadius > 0) canvas.drawCircle(o.startCenter, o.startRadius, paint);
      if (o.endRadius > 0) canvas.drawCircle(o.endCenter, o.endRadius, paint);
    }

    final a = controller.activeInk;
    if (a != null && a.points.isNotEmpty) {
      final o = InkOutlineBuilder.build(
        a.points,
        a.baseWidth,
        constantWidth: a.tool == InkTool.highlighter,
      );
      final paint = paintFor(a.tool, a.colorValue);
      canvas.drawPath(o.body, paint);
      if (o.startRadius > 0) canvas.drawCircle(o.startCenter, o.startRadius, paint);
      if (o.endRadius > 0) canvas.drawCircle(o.endCenter, o.endRadius, paint);
    }

    canvas.restore();
  }

  /// Highlighter ink multiplies with everything beneath it (other ink,
  /// paper, later PDF text in Step 4) at reduced alpha — it tints instead
  /// of covering, exactly like a real translucent marker.
  static Paint paintFor(InkTool tool, int colorValue) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = Color(colorValue);
    if (tool == InkTool.highlighter) {
      paint.color = Color(colorValue).withAlpha(115); // ≈45%
      paint.blendMode = BlendMode.multiply;
    }
    return paint;
  }

  @override
  bool shouldRepaint(InkPainter old) => true;
  // `repaint:` drives repaints; shouldRepaint only fires when the parent
  // rebuilds the painter instance — cheap and always safe.
}
