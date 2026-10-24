import 'package:flutter/material.dart';

import '../viewport_controller.dart';

/// Workspace backdrop + floating-page shadow — the GoodNotes/Notewise
/// reading look: a soft neutral workspace around the page, the page itself
/// lifted off it by a soft shadow.
///
/// Painted BELOW [PaperPainter] in the same Stack; both read the same
/// [viewport] matrix, so the shadow hugs the page at every pan/zoom (it is
/// computed from the page rect transformed to SCREEN space, which also
/// keeps the blur cost constant — the blur radius never grows with zoom).
class BackdropPainter extends CustomPainter {
  BackdropPainter({
    required this.backdropColor,
    required this.shadowColor,
    required this.pageSize,
    required this.viewport,
    this.cornerRadius = 2.5,
    this.shadowBlurSigma = 16,
    this.shadowOffset = const Offset(0, 4),
  }) : super(repaint: viewport);

  final Color backdropColor;
  final Color shadowColor;

  /// Logical page size in points (same convention as PaperPainter).
  final Size pageSize;
  final ViewportController viewport;

  /// Page-corner rounding in PAGE points (subtle — documents read square).
  final double cornerRadius;

  /// Shadow blur in SCREEN px (constant cost at any zoom).
  final double shadowBlurSigma;
  final Offset shadowOffset;

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Workspace fill (the whole canvas, page included — the paper
    //    painter covers the page area itself).
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = backdropColor,
    );

    // 2. Page rect in screen space.
    final a = viewport.pageToScreen(Offset.zero);
    final b = viewport.pageToScreen(
      Offset(pageSize.width, pageSize.height),
    );
    final rect = Rect.fromPoints(a, b);
    if (!rect.isFinite || rect.isEmpty) return;

    final scale = viewport.matrix.getMaxScaleOnAxis();
    final rRect = RRect.fromRectAndRadius(
      rect,
      Radius.circular((cornerRadius * scale).clamp(0.0, 12.0)),
    );

    // 3. Soft drop shadow (screen-space blur → constant GPU cost).
    final shadowPath = Path()..addRRect(rRect);
    canvas.drawPath(
      shadowPath.shift(shadowOffset),
      Paint()
        ..color = shadowColor
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadowBlurSigma),
    );
  }

  @override
  bool shouldRepaint(BackdropPainter old) =>
      old.backdropColor != backdropColor ||
      old.shadowColor != shadowColor ||
      old.pageSize != pageSize;
  // Viewport (matrix) changes flow through `repaint:` — no compare needed.
}
