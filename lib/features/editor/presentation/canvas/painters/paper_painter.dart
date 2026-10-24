import 'package:flutter/material.dart';

import '../../../../core/database/collections/document.dart';
import '../viewport_controller.dart';

/// Procedural paper background — ruled / grid / dotted / blank, light or
/// dark. Drawn in PAGE space inside the viewport transform: pattern lines
/// scale with zoom exactly like physical paper (GoodNotes behaviour) and
/// stay crisp at any zoom because they're vectors, not textures.
class PaperPainter extends CustomPainter {
  PaperPainter({
    required this.template,
    required this.shade,
    required this.pageSize,
    required this.viewport,
  }) : super(repaint: viewport);

  final PaperTemplate template;
  final PaperShade shade;
  final Size pageSize;
  final ViewportController viewport;

  static const double lineSpacing = 36; // ~ ruled pad
  static const double gridSpacing = 24;
  static const double dotSpacing = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final w = pageSize.width;
    final h = pageSize.height;

    final bg = shade == PaperShade.light ? const Color(0xFFFFFFFF) : const Color(0xFF141B24);
    final line = shade == PaperShade.light ? const Color(0xFFE2E8F0) : const Color(0xFF334155);
    final dot = shade == PaperShade.light ? const Color(0xFFCBD5E1) : const Color(0xFF475569);

    canvas.save();
    canvas.transform(viewport.matrix.storage);

    canvas.drawRect(Offset.zero & Size(w, h), Paint()..color = bg);

    switch (template) {
      case PaperTemplate.blank:
        break;
      case PaperTemplate.ruled:
        final p = Paint()
          ..color = line
          ..strokeWidth = 0.8
          ..style = PaintingStyle.stroke;
        var y = lineSpacing * 2.0; // top margin, like a real pad
        while (y < h) {
          canvas.drawLine(Offset(0, y), Offset(w, y), p);
          y += lineSpacing;
        }
        break;
      case PaperTemplate.grid:
        final p = Paint()
          ..color = line
          ..strokeWidth = 0.6
          ..style = PaintingStyle.stroke;
        var x = 0.0;
        while (x <= w) {
          canvas.drawLine(Offset(x, 0), Offset(x, h), p);
          x += gridSpacing;
        }
        var y = 0.0;
        while (y <= h) {
          canvas.drawLine(Offset(0, y), Offset(w, y), p);
          y += gridSpacing;
        }
        break;
      case PaperTemplate.dotted:
        final p = Paint()..color = dot;
        var y = dotSpacing / 2;
        while (y < h) {
          var x = dotSpacing / 2;
          while (x < w) {
            canvas.drawCircle(Offset(x, y), 0.9, p);
            x += dotSpacing;
          }
          y += dotSpacing;
        }
        break;
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(PaperPainter old) =>
      old.template != template || old.shade != shade || old.pageSize != pageSize;
  // Viewport (matrix) changes flow through `repaint:` — no compare needed.
}
