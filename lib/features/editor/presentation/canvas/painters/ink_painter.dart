import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../../core/database/collections/stroke.dart';
import '../../../domain/geometry/ink_geometry.dart';
import '../../../domain/models/stroke_codec.dart';
import '../ink_controller.dart';
import '../selection_controller.dart';
import '../viewport_controller.dart';

/// Renders committed ink (cached outlines) plus the live stroke and the
/// live shape ghosts — in PAGE space, inside the shared viewport transform.
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

      drawInkStroke(canvas, controller, s);
    }

    for (final s in controller.shapePreview) {
      if (s.maxX < visible.left || s.minX > visible.right) continue;
      if (s.maxY < visible.top || s.minY > visible.bottom) continue;
      drawInkStroke(canvas, controller, s);
    }

    final a = controller.activeInk;
    if (a != null && a.points.isNotEmpty) {
      _drawLiveStroke(canvas, a);
    }

    canvas.restore();
  }

  /// The live (uncommitted) stroke renders exactly like its committed form,
  /// including the pen style — no tessellation cache, rebuilt per frame.
  void _drawLiveStroke(Canvas canvas, ActiveInk a) {
    if (a.tool == InkTool.highlighter) {
      final o = InkOutlineBuilder.build(
        a.points,
        a.baseWidth,
        constantWidth: true,
      );
      final paint = paintFor(a.tool, a.colorValue, a.opacity);
      canvas.drawPath(o.body, paint);
      if (o.startRadius > 0) canvas.drawCircle(o.startCenter, o.startRadius, paint);
      if (o.endRadius > 0) canvas.drawCircle(o.endCenter, o.endRadius, paint);
      return;
    }

    final style = a.styleValue >= 0 && a.styleValue < PenStyle.values.length
        ? PenStyle.values[a.styleValue]
        : PenStyle.regular;

    switch (style) {
      case PenStyle.dashed:
      case PenStyle.rainbow:
        // Centerline-rendered styles share the committed drawing code —
        // drawInkStroke works on a Stroke row, so materialize a throwaway.
        final temp = strokeFromPoints(
          pageId: a.pageId,
          tool: a.tool,
          colorValue: a.colorValue,
          baseWidth: a.baseWidth,
          styleValue: a.styleValue,
          opacity: a.opacity,
          points: a.points,
        );
        drawInkStroke(canvas, null, temp);
        break;

      default:
        final o = InkOutlineBuilder.build(a.points, a.baseWidth, style: style);
        // Pencil/neon use the same two-pass treatment as committed ink.
        if (style == PenStyle.pencil || style == PenStyle.neon) {
          drawOutlinePasses(
            canvas,
            o,
            style,
            a.colorValue,
            a.opacity,
            a.baseWidth,
            centerline: [for (final p in a.points) p.position],
          );
        } else {
          final paint = paintFor(a.tool, a.colorValue, a.opacity);
          canvas.drawPath(o.body, paint);
          if (o.startRadius > 0) canvas.drawCircle(o.startCenter, o.startRadius, paint);
          if (o.endRadius > 0) canvas.drawCircle(o.endCenter, o.endRadius, paint);
        }
        break;
    }
  }

  /// Draws ONE stroke — pen/highlighter via the cached variable-width
  /// outline, shapes as a stroked polyline (crisp geometry with round
  /// joins — Notewise-style). Shared with [SelectionOverlayPainter] so the
  /// transformed selection preview renders identically.
  ///
  /// Pen styles (v1.3, XNota brush catalogue) branch here:
  ///  • regular / calligraphy / speed / taper — the cached outline (their
  ///    pressure profiles are baked into the tessellation);
  ///  • pencil — faded outline + offset centerline overlay (dry grain feel);
  ///  • neon — blurred halo pass + bright core pass (glow);
  ///  • dashed — stroked centerline with a computed dash pattern;
  ///  • rainbow — per-segment hue cycling along the centerline.
  static void drawInkStroke(Canvas canvas, InkController? ink, Stroke s) {
    if (s.tool == InkTool.shape) {
      final pts = s.readPoints();
      if (pts.isEmpty) return;
      final color = _alphaAdjusted(s.colorValue, s.opacity);
      if (pts.length == 1) {
        // Dot shape (a degenerate drag) — one round cap.
        canvas.drawCircle(
          pts.first.position,
          s.baseWidth / 2,
          Paint()
            ..color = color
            ..style = PaintingStyle.fill,
        );
        return;
      }
      final path = Path()..moveTo(pts.first.position.dx, pts.first.position.dy);
      for (final p in pts.skip(1)) {
        path.lineTo(p.position.dx, p.position.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = s.baseWidth
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      return;
    }

    if (s.tool == InkTool.highlighter) {
      final o = ink!.outlineOf(s);
      final paint = paintFor(s.tool, s.colorValue, s.opacity);
      canvas.drawPath(o.body, paint);
      if (o.startRadius > 0) canvas.drawCircle(o.startCenter, o.startRadius, paint);
      if (o.endRadius > 0) canvas.drawCircle(o.endCenter, o.endRadius, paint);
      return;
    }

    switch (s.penStyle) {
      case PenStyle.dashed:
        _drawDashedCenterline(canvas, s);
        return;

      case PenStyle.rainbow:
        _drawRainbowCenterline(canvas, s);
        return;

      case PenStyle.pencil:
      case PenStyle.neon:
        final o = ink!.outlineOf(s);
        drawOutlinePasses(
          canvas,
          o,
          s.penStyle,
          s.colorValue,
          s.opacity,
          s.baseWidth,
          centerline: [for (final p in s.readPoints()) p.position],
        );
        return;

      case PenStyle.regular:
      case PenStyle.calligraphy:
      case PenStyle.speed:
      case PenStyle.taper:
        final o = ink!.outlineOf(s);
        final paint = paintFor(s.tool, s.colorValue, s.opacity);
        canvas.drawPath(o.body, paint);
        if (o.startRadius > 0) canvas.drawCircle(o.startCenter, o.startRadius, paint);
        if (o.endRadius > 0) canvas.drawCircle(o.endCenter, o.endRadius, paint);
        return;
    }
  }

  /// Two-pass renderers for pencil (grainy fade) and neon (glow) that share
  /// the cached outline with the regular path. [centerline] is the raw
  /// stroke polyline — the pencil pass draws its grain along it.
  static void drawOutlinePasses(
    Canvas canvas,
    InkOutline o,
    PenStyle style,
    int colorValue,
    double opacity,
    double baseWidth, {
    List<Offset> centerline = const [],
  }) {
    final base = Color(colorValue);

    if (style == PenStyle.neon) {
      // Pass 1 — soft halo (blur scales with the nib size).
      final halo = Paint()
        ..style = PaintingStyle.fill
        ..color = _alphaAdjusted(colorValue, math.min(1.0, 0.9 * opacity))
        ..maskFilter = MaskFilter.blur(
            BlurStyle.normal, (baseWidth * 0.9).clamp(1.5, 14.0));
      canvas.drawPath(o.body, halo);
      // Pass 2 — bright core, tinted toward white like a lit filament.
      final core = Paint()
        ..style = PaintingStyle.fill
        ..color = Color.alphaBlend(
                Colors.white.withOpacity(0.45 * opacity), base)
            .withOpacity(math.max(0.15, 0.9 * opacity));
      canvas.drawPath(o.body, core);
      return;
    }

    // Pencil — faded body + grainy offset centerline.
    final body = Paint()
      ..style = PaintingStyle.fill
      ..color = _alphaAdjusted(colorValue, 0.62 * opacity);
    canvas.drawPath(o.body, body);
    if (o.startRadius > 0) canvas.drawCircle(o.startCenter, o.startRadius, body);
    if (o.endRadius > 0) canvas.drawCircle(o.endCenter, o.endRadius, body);
    if (centerline.length < 2) return;
    final grain = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(0.4, baseWidth * 0.3)
      ..color = _alphaAdjusted(colorValue, 0.3 * opacity);
    for (var i = 0; i + 1 < centerline.length; i++) {
      canvas.drawLine(centerline[i] + const Offset(0.35, 0.35),
          centerline[i + 1] + const Offset(0.35, 0.35), grain);
    }
  }

  /// Dashed pen — a stroked centerline with a computed dash pattern
  /// (Canvas has no native dash support; we walk the polyline).
  static void _drawDashedCenterline(Canvas canvas, Stroke s) {
    final pts = s.readPoints();
    if (pts.isEmpty) return;
    final color = _alphaAdjusted(s.colorValue, s.opacity);
    if (pts.length == 1) {
      canvas.drawCircle(pts.first.position, s.baseWidth / 2,
          Paint()..color = color);
      return;
    }
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, s.baseWidth * 0.8)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final dash = (s.baseWidth * 3.2).clamp(3.0, 14.0);
    final gap = dash * 0.8;
    var remaining = dash;
    var drawing = true;
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i].position;
      final b = pts[i + 1].position;
      final len = (b - a).distance;
      if (len < 1e-6) continue;
      var t0 = 0.0;
      var t1 = 0.0;
      while (t0 < len) {
        t1 = math.min(len, t0 + remaining);
        if (drawing) {
          canvas.drawLine(
            Offset(a.dx + (b.dx - a.dx) * t0 / len, a.dy + (b.dy - a.dy) * t0 / len),
            Offset(a.dx + (b.dx - a.dx) * t1 / len, a.dy + (b.dy - a.dy) * t1 / len),
            paint,
          );
        }
        remaining -= (t1 - t0);
        if (remaining <= 0) {
          drawing = !drawing;
          remaining = drawing ? dash : gap;
        }
        t0 = t1;
      }
    }
  }

  /// Rainbow pen — hue cycles along the centerline, width from pressure.
  static void _drawRainbowCenterline(Canvas canvas, Stroke s) {
    final pts = s.readPoints();
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      canvas.drawCircle(pts.first.position, s.baseWidth / 2,
          Paint()..color = _alphaAdjusted(s.colorValue, s.opacity));
      return;
    }
    // Deterministic starting hue per stroke so re-renders are stable.
    var hue = ((s.id % 60) * 6.0) % 360.0;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (var i = 0; i + 1 < pts.length; i++) {
      final w = (s.baseWidth *
              (InkOutlineBuilder.kMinPressureFactor +
                  (1 - InkOutlineBuilder.kMinPressureFactor) *
                      pts[i].pressure))
          .clamp(0.6, 40.0);
      paint
        ..color = HSVColor.fromAHSV(
                math.max(0.25, s.opacity), hue % 360, 0.85, 1.0)
            .toColor()
        ..strokeWidth = w;
      canvas.drawLine(pts[i].position, pts[i + 1].position, paint);
      hue += 5.0;
    }
  }

  /// Highlighter ink multiplies with everything beneath it (other ink,
  /// paper, PDF text) at reduced alpha — it tints instead of covering,
  /// exactly like a real translucent marker.
  static Paint paintFor(InkTool tool, int colorValue, [double opacity = 1.0]) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = _alphaAdjusted(colorValue, opacity);
    if (tool == InkTool.highlighter) {
      paint.color = Color(colorValue).withAlpha(115); // ≈45%
      paint.blendMode = BlendMode.multiply;
    }
    return paint;
  }

  /// Applies the stored stroke opacity on top of the color's own alpha.
  static Color _alphaAdjusted(int colorValue, double opacity) {
    final c = Color(colorValue);
    final o = opacity.clamp(0.1, 1.0);
    if (o >= 0.999) return c;
    return c.withOpacity(c.opacity * o);
  }

  @override
  bool shouldRepaint(InkPainter old) => true;
  // `repaint:` drives repaints; shouldRepaint only fires when the parent
  // rebuilds the painter instance — cheap and always safe.
}
