import 'package:flutter/material.dart';

import '../../../../../core/database/collections/document.dart';

/// Procedural mini paper preview — for notebook covers in the library grid
/// and template pickers. Deliberately NOT [PaperPainter]: the canvas painter
/// draws in page space under a viewport matrix; previews draw in their own
/// box with pattern spacing scaled down from A4, no viewport attached.
class PaperPreview extends StatelessWidget {
  const PaperPreview({
    super.key,
    required this.template,
    required this.shade,
    this.cornerRadius = 8,
  });

  final PaperTemplate template;
  final PaperShade shade;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(cornerRadius),
      child: CustomPaint(
        painter: _PaperPreviewPainter(template: template, shade: shade),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _PaperPreviewPainter extends CustomPainter {
  _PaperPreviewPainter({required this.template, required this.shade});

  final PaperTemplate template;
  final PaperShade shade;

  @override
  void paint(Canvas canvas, Size size) {
    // A4 logical size — the preview is a shrunken A4 sheet.
    const a4 = Size(595.28, 841.89);
    final scale = size.width / a4.width;

    final bg = shade == PaperShade.light
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF141B24);
    final line = shade == PaperShade.light
        ? const Color(0xFFE2E8F0)
        : const Color(0xFF334155);
    final dot = shade == PaperShade.light
        ? const Color(0xFFCBD5E1)
        : const Color(0xFF475569);

    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    switch (template) {
      case PaperTemplate.blank:
        break;
      case PaperTemplate.ruled:
        final p = Paint()
          ..color = line
          // 1/scale CANCELS the preview shrink: spacing stays proportional
          // (×scale) while line weight stays ~0.8–1.2 px on any preview size
          // — tiny thumbs keep a legible pattern instead of hairlines.
          ..strokeWidth = (0.8 / scale).clamp(0.5, 1.2)
          ..style = PaintingStyle.stroke;
        var y = 72.0 * scale; // same top margin as the real paper painter
        while (y < size.height) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
          y += 36 * scale;
        }
        break;
      case PaperTemplate.grid:
        final p = Paint()
          ..color = line
          ..strokeWidth = (0.6 / scale).clamp(0.4, 1.0)
          ..style = PaintingStyle.stroke;
        var x = 0.0;
        while (x <= size.width) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
          x += 24 * scale;
        }
        var y = 0.0;
        while (y <= size.height) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
          y += 24 * scale;
        }
        break;
      case PaperTemplate.dotted:
        final r = (0.9 / scale).clamp(0.6, 1.5);
        final p = Paint()..color = dot;
        var y = 12 * scale;
        while (y < size.height) {
          var x = 12 * scale;
          while (x < size.width) {
            canvas.drawCircle(Offset(x, y), r, p);
            x += 24 * scale;
          }
          y += 24 * scale;
        }
        break;
    }
  }

  @override
  bool shouldRepaint(_PaperPreviewPainter old) =>
      old.template != template || old.shade != shade;
}
