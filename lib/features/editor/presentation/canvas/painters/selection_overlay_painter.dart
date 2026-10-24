import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ink_controller.dart';
import '../selection_controller.dart';
import '../viewport_controller.dart';
import 'ink_painter.dart';

/// Draws, in SCREEN space (constant weights regardless of zoom):
///  • the live lasso loop (dashed, auto-closed);
///  • the selection frame + constant-size grab handles + rotate handle;
///  • and, while transforming, the transformed ink PREVIEW — the originals
///    are simultaneously suppressed by [InkPainter], so ink appears to
///    follow the gesture. The preview reuses the committed outline cache:
///    one cached [Path] per stroke, re-projected through the combined
///    viewport·gesture matrix per frame.
class SelectionOverlayPainter extends CustomPainter {
  SelectionOverlayPainter({
    required this.selection,
    required this.ink,
    required this.viewport,
    this.accentColor = const Color(0xFF155EEF),
  }) : super(repaint: Listenable.merge([selection, viewport]));

  final SelectionController selection;
  final InkController ink;
  final ViewportController viewport;

  /// Brand accent for the lasso/frame/handles — injected so the editor
  /// shell (Step 5) can follow the active theme without a BuildContext.
  final Color accentColor;

  static const double _dash = 7;
  static const double _gap = 5;

  @override
  void paint(Canvas canvas, Size size) {
    // 1 ── Transformed ink preview.
    if (selection.isTransforming) {
      final m = selection.liveMatrix!;
      final combined = Matrix4.copy(viewport.matrix)..multiply(m);
      canvas.save();
      canvas.transform(combined.storage);
      for (final s in ink.strokes) {
        if (!selection.isSelected(s)) continue;
        InkPainter.drawInkStroke(canvas, ink, s);
      }
      canvas.restore();
    }

    // 2 ── Live lasso loop.
    if (selection.loop.isNotEmpty) {
      final path = Path()
        ..addPolygon(
          [for (final p in selection.loop) viewport.pageToScreen(p)],
          true,
        );
      _drawDashed(
        canvas,
        path,
        Paint()
          ..color = accentColor.withAlpha(220)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    // 3 ── Selection frame + handles.
    if (selection.hasSelection) {
      final b = selection.selectionBounds();
      Offset sp(Offset p) => viewport.pageToScreen(p);
      final tl = sp(b.topLeft), tr = sp(b.topRight);
      final bl = sp(b.bottomLeft), br = sp(b.bottomRight);

      _drawDashed(
        canvas,
        Path()..addPolygon([tl, tr, br, bl], true),
        Paint()
          ..color = accentColor.withAlpha(200)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );

      final fill = Paint()..color = Colors.white;
      final border = Paint()
        ..color = accentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;

      void square(Offset c) {
        final rrect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: 12, height: 12),
          const Radius.circular(3),
        );
        canvas.drawRRect(rrect, fill);
        canvas.drawRRect(rrect, border);
      }

      square(tl);
      square(tr);
      square(br);
      square(bl);

      // Rotate handle above top-center, joined by a stem.
      final top = sp(Offset(b.center.dx, b.top));
      final rot = top + const Offset(0, -SelectionController.rotateHandleGap);
      canvas.drawLine(
        top,
        rot,
        Paint()
          ..color = accentColor.withAlpha(200)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
      canvas.drawCircle(rot, 7, fill);
      canvas.drawCircle(rot, 7, border);
    }
  }

  void _drawDashed(Canvas canvas, Path source, Paint paint) {
    for (final metric in source.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = math.min(d + _dash, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(SelectionOverlayPainter old) => true;
}
