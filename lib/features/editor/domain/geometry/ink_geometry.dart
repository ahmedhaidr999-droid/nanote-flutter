import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/database/collections/stroke.dart' show PenStyle;
import '../models/stroke_point.dart';

/// Pure geometry for the vector ink engine.
///
/// Everything here operates in PAGE coordinates (logical points) and only
/// depends on [Offset]/[Path] — unit-testable, painter-agnostic.

// ─────────────────────────────────────────────────────────────────────────
// Distances & hit-testing
// ─────────────────────────────────────────────────────────────────────────

/// Distance from point [p] to segment [a]–[b].
double distanceToSegment(Offset p, Offset a, Offset b) {
  final abx = b.dx - a.dx;
  final aby = b.dy - a.dy;
  final apx = p.dx - a.dx;
  final apy = p.dy - a.dy;
  final len2 = abx * abx + aby * aby;
  var t = 0.0;
  if (len2 > 1e-12) {
    t = ((apx * abx) + (apy * aby)) / len2;
    t = t.clamp(0.0, 1.0);
  }
  final dx = p.dx - (a.dx + abx * t);
  final dy = p.dy - (a.dy + aby * t);
  return math.sqrt(dx * dx + dy * dy);
}

/// Minimum distance from [p] to the polyline [pts].
double distanceToPolyline(Offset p, List<StrokePoint> pts) {
  if (pts.isEmpty) return double.infinity;
  if (pts.length == 1) return (p - pts.first.position).distance;
  var best = double.infinity;
  for (var i = 0; i < pts.length - 1; i++) {
    final d = distanceToSegment(p, pts[i].position, pts[i + 1].position);
    if (d < best) best = d;
  }
  return best;
}

// ─────────────────────────────────────────────────────────────────────────
// Bézier smoothing (Catmull–Rom → cubic Bézier)
// ─────────────────────────────────────────────────────────────────────────

/// Smooths an arbitrary polyline into cubic Bézier segments written into
/// [path] (uniform Catmull–Rom, the classic control-point conversion):
///
///     C1 = P1 + (P2 − P0) / 6        C2 = P2 − (P3 − P1) / 6
///
/// Endpoints are virtually duplicated. [startWithMove] false continues an
/// already-open subpath (used when chaining left/right outline sides).
void smoothPathInto(Path path, List<Offset> pts, {required bool startWithMove}) {
  final n = pts.length;
  if (n == 0) return;
  if (startWithMove) path.moveTo(pts.first.dx, pts.first.dy);
  for (var i = 0; i < n - 1; i++) {
    final p0 = pts[i > 0 ? i - 1 : 0];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final p3 = pts[i + 2 < n ? i + 2 : n - 1];
    path.cubicTo(
      p1.dx + (p2.dx - p0.dx) / 6,
      p1.dy + (p2.dy - p0.dy) / 6,
      p2.dx - (p3.dx - p1.dx) / 6,
      p2.dy - (p3.dy - p1.dy) / 6,
      p2.dx,
      p2.dy,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Variable-width stroke outline
// ─────────────────────────────────────────────────────────────────────────

/// The tessellated render form of one stroke: a filled variable-width body
/// plus round end-caps. Caps are drawn as separate circles by the painter —
/// merging them into one path would hit non-zero winding-order pitfalls
/// when cap and body wind in opposite directions.
class InkOutline {
  const InkOutline({
    required this.body,
    required this.startCenter,
    required this.startRadius,
    required this.endCenter,
    required this.endRadius,
  });

  final Path body;
  final Offset startCenter;
  final double startRadius;
  final Offset endCenter;
  final double endRadius;

  static final InkOutline empty = InkOutline(
    body: Path(),
    startCenter: Offset.zero,
    startRadius: 0,
    endCenter: Offset.zero,
    endRadius: 0,
  );
}

class InkOutlineBuilder {
  InkOutlineBuilder._();

  /// Pressure 0 maps to 35% of base width — the faint end of the stylus
  /// range stays visible instead of collapsing to nothing.
  static const double kMinPressureFactor = 0.35;

  /// Style strokes (taper/speed/calligraphy) synthesize their own pressure
  /// profiles — their floor is much lower so the effect can read clearly.
  static const double _kStyleMinPressureFactor = 0.08;

  /// Nib direction for the calligraphy style (radians). −π/4 = italic —
  /// horizontal strokes are fat, vertical strokes are hairlines.
  static const double _kCalligraphyNibAngle = -math.pi / 4;

  static double halfWidth(
    double baseWidth,
    double pressure, [
    double minFactor = kMinPressureFactor,
  ]) =>
      baseWidth *
      (minFactor + (1 - minFactor) * pressure) *
      0.5;

  /// Effective pressure per point for [style] (same length as [pts]).
  ///
  /// Geometry-affecting styles remap the raw stylus pressure:
  ///  • taper — ramps both ends down to ~12% (feathered entry/exit);
  ///  • speed — width from LOCAL SPACING (a proxy for velocity: the 1-pt
  ///    minimum point distance means fast strokes land points far apart) —
  ///    fast = thin, slow = thick, like a loaded ink brush;
  ///  • calligraphy — width from the angle between the stroke direction
  ///    and a fixed nib angle; pressure is ignored entirely.
  static List<double> _effectivePressures(
    List<StrokePoint> pts,
    PenStyle style,
  ) {
    final n = pts.length;
    final out = List<double>.filled(n, 1.0, growable: false);
    switch (style) {
      case PenStyle.regular:
      case PenStyle.pencil:
      case PenStyle.neon:
      case PenStyle.dashed:
      case PenStyle.rainbow:
        for (var i = 0; i < n; i++) {
          out[i] = pts[i].pressure;
        }
        return out;

      case PenStyle.taper:
        final ramp = math.max(1, (n * 0.22).floor());
        for (var i = 0; i < n; i++) {
          final edge = math.min(i, n - 1 - i);
          final f = (edge / ramp).clamp(0.12, 1.0);
          out[i] = pts[i].pressure * f;
        }
        return out;

      case PenStyle.speed:
        for (var i = 0; i < n; i++) {
          final d = i == 0
              ? 1.0
              : (pts[i].position - pts[i - 1].position).distance;
          // Spacing 1 pt (slow) → full width; ~14 pt (fast) → 28% width.
          final v = (1.1 - d / 14.0).clamp(0.28, 1.0);
          out[i] = pts[i].pressure * v;
        }
        return out;

      case PenStyle.calligraphy:
        for (var i = 0; i < n; i++) {
          final prev = pts[i > 0 ? i - 1 : 0].position;
          final next = pts[i < n - 1 ? i + 1 : n - 1].position;
          final dir = next - prev;
          final len = dir.distance;
          if (len < 1e-6) {
            out[i] = 1.0;
            continue;
          }
          final angle = math.atan2(dir.dy, dir.dx);
          final d = (angle - _kCalligraphyNibAngle).abs();
          // Width ∝ how close the motion is to the nib's broad axis.
          out[i] = math.sin(d).abs().clamp(0.1, 1.0);
        }
        return out;
    }
  }

  /// Whether [style] needs the lower width floor so its synthetic profile
  /// can actually go thin (see [_kStyleMinPressureFactor]).
  static bool _usesLowFloor(PenStyle style) =>
      style == PenStyle.taper ||
      style == PenStyle.speed ||
      style == PenStyle.calligraphy;

  /// Public view of [_effectivePressures] — the exporter reuses the exact
  /// width profiles when it rasterizes/prints strokes outside the painter.
  static List<double> effectivePressuresOf(
          List<StrokePoint> pts, PenStyle style) =>
      _effectivePressures(pts, style);

  /// Builds the fill-able outline of a stroke:
  ///  1. unit tangent per point (central differences, one-sided at ends);
  ///  2. left/right offset polylines at ± halfWidth(pressure);
  ///  3. both sides Catmull–Rom smoothed — body = left forward + right
  ///     backward, closed; caps = endpoint circles.
  ///
  /// [constantWidth] disables the pressure curve (highlighter): the width
  /// is a flat band, exactly like a chisel marker.
  ///
  /// [style] selects a geometry-affecting pen profile (see
  /// [_effectivePressures]) — regular rendering styles pass through the raw
  /// pressures unchanged.
  static InkOutline build(
    List<StrokePoint> pts,
    double baseWidth, {
    bool constantWidth = false,
    PenStyle style = PenStyle.regular,
  }) {
    if (pts.isEmpty) return InkOutline.empty;

    final first = pts.first;
    final last = pts.last;
    final minFactor = _usesLowFloor(style)
        ? _kStyleMinPressureFactor
        : kMinPressureFactor;
    final pressures = constantWidth
        ? null
        : _effectivePressures(pts, style);
    final rStart = constantWidth
        ? baseWidth * 0.5
        : halfWidth(baseWidth, pressures![0], minFactor);

    if (pts.length == 1 || (last.position - first.position).distance < 0.5) {
      // Dot — a single cap carries the whole ink.
      return InkOutline(
        body: Path(),
        startCenter: first.position,
        startRadius: rStart,
        endCenter: first.position,
        endRadius: rStart,
      );
    }

    final n = pts.length;
    final left = List<Offset>.filled(n, Offset.zero);
    final right = List<Offset>.filled(n, Offset.zero);

    for (var i = 0; i < n; i++) {
      final prev = pts[i > 0 ? i - 1 : 0].position;
      final next = pts[i < n - 1 ? i + 1 : n - 1].position;
      var tx = next.dx - prev.dx;
      var ty = next.dy - prev.dy;
      final len = math.sqrt(tx * tx + ty * ty);
      if (len < 1e-6) {
        tx = 1;
        ty = 0;
      } else {
        tx /= len;
        ty /= len;
      }
      final h = constantWidth
          ? baseWidth * 0.5
          : halfWidth(baseWidth, pressures![i], minFactor);
      final p = pts[i].position;
      // Left normal = (−ty, tx).
      left[i] = Offset(p.dx - ty * h, p.dy + tx * h);
      right[i] = Offset(p.dx + ty * h, p.dy - tx * h);
    }

    final body = Path();
    smoothPathInto(body, left, startWithMove: true);
    smoothPathInto(body, right.reversed.toList(growable: false), startWithMove: false);
    body.close();

    return InkOutline(
      body: body,
      startCenter: first.position,
      startRadius: rStart,
      endCenter: last.position,
      endRadius: constantWidth
          ? baseWidth * 0.5
          : halfWidth(baseWidth, pressures![n - 1], minFactor),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Pixel eraser — vector stroke splitting
// ─────────────────────────────────────────────────────────────────────────

/// Splits a stroke against an eraser CAPSULE (segment a–b with radius r —
/// the area swept between two pointer samples).
///
/// Returns `null` when untouched. Surviving contiguous runs become the
/// replacement strokes; a single surviving point becomes a dot stroke.
/// This is the vector equivalent of a pixel eraser: the exact touched span
/// disappears while the rest of the line keeps its original geometry,
/// pressure profile and z-position.
List<List<StrokePoint>>? splitByEraserCapsule(
  List<StrokePoint> pts,
  Offset a,
  Offset b,
  double r,
) {
  if (pts.isEmpty) return null;

  var touched = false;
  final runs = <List<StrokePoint>>[];
  var current = <StrokePoint>[];

  for (final p in pts) {
    if (distanceToSegment(p.position, a, b) < r) {
      touched = true;
      if (current.isNotEmpty) {
        runs.add(current);
        current = <StrokePoint>[];
      }
    } else {
      current.add(p);
    }
  }
  if (current.isNotEmpty) runs.add(current);

  return touched ? runs : null;
}

// ─────────────────────────────────────────────────────────────────────────
// Lasso geometry
// ─────────────────────────────────────────────────────────────────────────

double _cross(Offset o, Offset a, Offset b) =>
    (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

/// Ray-casting point-in-polygon. [poly] is treated as implicitly closed.
bool pointInPolygon(Offset p, List<Offset> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final pi = poly[i];
    final pj = poly[j];
    if (((pi.dy > p.dy) != (pj.dy > p.dy)) &&
        (p.dx <
            (pj.dx - pi.dx) * (p.dy - pi.dy) / (pj.dy - pi.dy) + pi.dx)) {
      inside = !inside;
    }
  }
  return inside;
}

/// Proper segment–segment intersection (strict sign test — touching
/// endpoints don't count, which is fine: endpoints inside the loop are
/// already covered by [pointInPolygon]).
bool segmentsIntersect(Offset a1, Offset a2, Offset b1, Offset b2) {
  final d1 = _cross(b1, b2, a1);
  final d2 = _cross(b1, b2, a2);
  final d3 = _cross(a1, a2, b1);
  final d4 = _cross(a1, a2, b2);
  return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
}

/// Whether segment a–b crosses any edge of the (implicitly closed) polygon.
bool segmentIntersectsPolygon(Offset a, Offset b, List<Offset> poly) {
  for (var i = 0; i < poly.length; i++) {
    final c = poly[i];
    final d = poly[(i + 1) % poly.length];
    if (segmentsIntersect(a, b, c, d)) return true;
  }
  return false;
}

Rect polygonBounds(List<Offset> poly) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final p in poly) {
    if (p.dx < minX) minX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy > maxY) maxY = p.dy;
  }
  if (poly.isEmpty) return Rect.zero;
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}
