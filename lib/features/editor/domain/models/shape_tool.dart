import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'stroke_point.dart';

/// The shape tool's catalogue (Notewise parity). Runtime-only — never
/// persisted; a committed shape becomes ordinary [Stroke] rows.
enum ShapeType { line, arrow, rectangle, ellipse, triangle }

/// Samples [type] dragged from [a] to [b] into one or more polylines
/// (page coordinates).
///
///  • line / rectangle / ellipse / triangle → ONE polyline;
///  • arrow → THREE polylines (shaft + two head barbs) which commit together
///    as a single undo unit.
///
/// Straight-edged shapes are sampled with corner points only: the renderer
/// strokes the polyline with round joins (crisp Notewise-style shapes) and
/// the eraser's capsule test evaluates the exact edge segments. The ellipse
/// needs a dense parametric sample to approximate the curve.
List<List<StrokePoint>> sampleShape(ShapeType type, Offset a, Offset b) {
  switch (type) {
    case ShapeType.line:
      return [
        [StrokePoint(a, 0.5), StrokePoint(b, 0.5)],
      ];

    case ShapeType.arrow:
      final dir = b - a;
      final len = dir.distance;
      if (len < 2) {
        return [
          [StrokePoint(a, 0.5), StrokePoint(b, 0.5)],
        ];
      }
      final u = dir / len; // unit along the shaft
      // Head size scales with the shaft but stays inside sane bounds
      // (page points).
      final head = (len * 0.25).clamp(10.0, 42.0);
      final wing = math.pi / 7; // ≈26° per barb
      final c = math.cos(wing);
      final s = math.sin(wing);
      // Barbs point BACKWARDS from the tip along ±wing of the shaft.
      final back1 = Offset(
        b.dx - u.dx * head * c + u.dy * head * s,
        b.dy - u.dy * head * c - u.dx * head * s,
      );
      final back2 = Offset(
        b.dx - u.dx * head * c - u.dy * head * s,
        b.dy - u.dy * head * c + u.dx * head * s,
      );
      return [
        [StrokePoint(a, 0.5), StrokePoint(b, 0.5)],
        [StrokePoint(b, 0.5), StrokePoint(back1, 0.5)],
        [StrokePoint(b, 0.5), StrokePoint(back2, 0.5)],
      ];

    case ShapeType.rectangle:
      final tl = Offset(math.min(a.dx, b.dx), math.min(a.dy, b.dy));
      final br = Offset(math.max(a.dx, b.dx), math.max(a.dy, b.dy));
      final tr = Offset(br.dx, tl.dy);
      final bl = Offset(tl.dx, br.dy);
      return [
        [
          StrokePoint(tl, 0.5),
          StrokePoint(tr, 0.5),
          StrokePoint(br, 0.5),
          StrokePoint(bl, 0.5),
          StrokePoint(tl, 0.5), // close the loop
        ],
      ];

    case ShapeType.ellipse:
      final rect = Rect.fromPoints(a, b);
      if (rect.width < 2 || rect.height < 2) {
        return [
          [StrokePoint(a, 0.5), StrokePoint(b, 0.5)],
        ];
      }
      final cx = rect.center.dx;
      final cy = rect.center.dy;
      final rx = rect.width / 2;
      final ry = rect.height / 2;
      const segments = 72;
      final pts = <StrokePoint>[];
      for (var i = 0; i <= segments; i++) {
        final t = i / segments * 2 * math.pi;
        pts.add(StrokePoint(
          Offset(cx + math.cos(t) * rx, cy + math.sin(t) * ry),
          0.5,
        ));
      }
      return [pts];

    case ShapeType.triangle:
      final rect = Rect.fromPoints(a, b);
      final apex = Offset(rect.center.dx, rect.top);
      return [
        [
          StrokePoint(apex, 0.5),
          StrokePoint(rect.bottomLeft, 0.5),
          StrokePoint(rect.bottomRight, 0.5),
          StrokePoint(apex, 0.5), // close the loop
        ],
      ];
  }
}
