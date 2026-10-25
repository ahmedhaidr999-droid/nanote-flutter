import 'package:flutter/material.dart';

import '../text_layer_controller.dart';
import '../viewport_controller.dart';

/// Renders the page's text blocks — above the ink layer, inside the shared
/// viewport.
///
/// CRISPNESS NOTE: glyphs are laid out at `fontSize × current zoom` in
/// SCREEN pixels and positioned at the transformed anchor. Scaling a
/// pre-laid-out glyph raster (the other option) would blur at high zoom;
/// re-laying the text per zoom bucket keeps text razor-sharp at 800%.
class TextBlockPainter extends CustomPainter {
  TextBlockPainter({required this.controller, required this.viewport})
      : super(repaint: Listenable.merge([controller, viewport]));

  final TextLayerController controller;
  final ViewportController viewport;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = viewport.scale;

    for (final b in controller.blocks) {
      final origin = viewport.pageToScreen(Offset(b.x, b.y));

      // Cull: skip blocks whose screen bbox lies fully outside the canvas.
      final logicalSize = controller.measureOf(b);
      final screenBox =
          origin & Size(logicalSize.width * scale, logicalSize.height * scale);
      if (screenBox.right < 0 ||
          screenBox.left > size.width ||
          screenBox.bottom < 0 ||
          screenBox.top > size.height) {
        continue;
      }

      // Sticky-note background — a rounded, shadowed swatch with breathing
      // room around the glyphs (XNota-style sticky).
      if (b.stickyColorValue != 0) {
        final pad = 9.0 * scale;
        final bgRect = Rect.fromLTRB(
          screenBox.left - pad,
          screenBox.top - pad,
          screenBox.right + pad,
          screenBox.bottom + pad,
        );
        final rRadius = 6.0 * scale;
        final bgRRect = RRect.fromRectAndRadius(bgRect, Radius.circular(rRadius));
        canvas.drawRRect(
          bgRRect.shift(Offset(0, 2.5 * scale)),
          Paint()
            ..color = const Color(0x26000000)
            ..maskFilter =
                MaskFilter.blur(BlurStyle.normal, 4.0 * scale),
        );
        canvas.drawRRect(
          bgRRect,
          Paint()..color = Color(b.stickyColorValue),
        );
      }

      final tp = TextPainter(
        text: TextSpan(
          text: b.content,
          style: TextStyle(
            fontSize: b.fontSize * scale,
            height: 1.28,
            color: Color(b.colorValue),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      // Subtle halo under dark text keeps it readable over PDF scans.
      final halo = (b.fontSize * scale) / 14;
      if (halo > 0.4) {
        final haloPainter = TextPainter(
          text: TextSpan(
            text: b.content,
            style: TextStyle(
              fontSize: b.fontSize * scale,
              height: 1.28,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = halo
                ..color = Colors.white.withAlpha(110)
                ..strokeJoin = StrokeJoin.round,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        haloPainter.paint(canvas, origin);
        haloPainter.dispose();
      }

      tp.paint(canvas, origin);
      tp.dispose();

      if (controller.activeDragBlock == b) {
        _drawDashedFrame(canvas, screenBox.inflate(6 * scale));
      }
    }
  }

  void _drawDashedFrame(Canvas canvas, Rect r) {
    const dash = 7.0;
    const gap = 5.0;
    final paint = Paint()
      ..color = const Color(0xFF155EEF).withAlpha(200)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    void dashedSide(Offset a, Offset b) {
      final len = (b - a).distance;
      if (len < 1) return;
      final u = (b - a) / len;
      var d = 0.0;
      while (d < len) {
        final end = (d + dash).clamp(0.0, len);
        canvas.drawLine(a + u * d, a + u * end, paint);
        d = end + gap;
      }
    }

    dashedSide(r.topLeft, r.topRight);
    dashedSide(r.topRight, r.bottomRight);
    dashedSide(r.bottomRight, r.bottomLeft);
    dashedSide(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(TextBlockPainter old) => true;
  // `repaint:` (controller ∪ viewport) drives repaints; shouldRepaint
  // covers parent rebuilds — cheap and always safe.
}
