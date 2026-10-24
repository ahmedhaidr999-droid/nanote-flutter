import 'package:flutter/material.dart';

import '../../../../core/database/collections/stroke.dart';
import 'stroke_point.dart';

/// Bridges the Isar [Stroke] row (flat doubles) and the runtime point list.
///
/// Kept as an extension + factory in the editor feature so the core
/// database layer never depends on feature code.
extension StrokeCodec on Stroke {
  /// Decodes [Stroke.coords] triples into typed points (single pass).
  List<StrokePoint> readPoints() {
    final out = <StrokePoint>[];
    final c = coords;
    for (var i = 0; i + 2 < c.length; i += 3) {
      out.add(StrokePoint(Offset(c[i], c[i + 1]), c[i + 2]));
    }
    return out;
  }
}

/// Materializes a stroke row from live input, maintaining the denormalized
/// bbox (used for culling + hit-test prefilters).
Stroke strokeFromPoints({
  required int pageId,
  required InkTool tool,
  required int colorValue,
  required double baseWidth,
  required List<StrokePoint> points,
}) {
  final s = Stroke()
    ..pageId = pageId
    ..tool = tool
    ..colorValue = colorValue
    ..baseWidth = baseWidth;

  final c = List<double>.filled(points.length * 3, 0, growable: false);
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;

  for (var i = 0; i < points.length; i++) {
    final p = points[i].position;
    c[i * 3] = p.dx;
    c[i * 3 + 1] = p.dy;
    c[i * 3 + 2] = points[i].pressure;
    if (p.dx < minX) minX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy > maxY) maxY = p.dy;
  }

  if (points.isEmpty) {
    minX = minY = maxX = maxY = 0;
  }

  return s
    ..coords = c
    ..minX = minX
    ..minY = minY
    ..maxX = maxX
    ..maxY = maxY;
}
