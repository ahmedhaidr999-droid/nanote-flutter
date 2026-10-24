import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show MatrixUtils;

/// Owns the page↔screen transform (pan + zoom only — rotation is applied to
/// SELECTED ink in Step 3, never to the viewport itself, so page↔screen
/// math stays a rigid scale+translate).
///
/// Both the paper painter, the (Step 4) PDF layer and the ink painter read
/// the SAME instance — that single source of truth is what guarantees
/// perfect layer alignment at any zoom.
class ViewportController extends ChangeNotifier {
  ViewportController({this.pageWidth = 595.28, this.pageHeight = 841.89});

  final double pageWidth;
  final double pageHeight;

  static const double minScale = 0.25;
  /// 800% — beyond the spec's 500% requirement; vector ink stays crisp and
  /// the Step-4 PDF tile cache serves raster at this depth.
  static const double maxScale = 8.0;

  /// Last canvas size the hosting page view laid out under (screen px,
  /// excludes app bar / toolbar chrome). Written by EditorPageView so the
  /// editor's "fit page" button fits the VISIBLE canvas, not the screen.
  Size? canvasSize;

  Matrix4 _matrix = Matrix4.identity();
  Matrix4 _inverse = Matrix4.identity();
  Matrix4 get matrix => _matrix;

  Offset pageToScreen(Offset p) => MatrixUtils.transformPoint(_matrix, p);
  Offset screenToPage(Offset p) => MatrixUtils.transformPoint(_inverse, p);

  /// The page-space rectangle currently visible (used for stroke culling).
  Rect visiblePageRect(Size viewportSize) {
    final a = screenToPage(Offset.zero);
    final b = screenToPage(Offset(viewportSize.width, viewportSize.height));
    return Rect.fromPoints(a, b);
  }

  void _set(Matrix4 m) {
    _matrix = m;
    try {
      _inverse = Matrix4.inverted(m);
    } catch (_) {
      _inverse = Matrix4.identity();
    }
    notifyListeners();
  }

  /// Pan in SCREEN space.
  void panBy(Offset screenDelta) {
    if (screenDelta == Offset.zero) return;
    final m = Matrix4.identity()
      ..translate(screenDelta.dx, screenDelta.dy);
    m.multiply(_matrix);
    _set(m);
  }

  /// Pinch around a moving focal point, relative to a snapshot taken when
  /// the gesture began:
  ///
  ///     M′ = T(newFocal) · S(ratio) · T(−baseFocal) · base
  ///
  /// The scale ratio is clamped so the result never leaves
  /// [minScale, maxScale]. Pan falls out of the focal translation for free.
  void applyPinch({
    required Matrix4 base,
    required Offset baseFocal,
    required Offset newFocal,
    required double ratio,
  }) {
    final baseScale = base.getMaxScaleOnAxis();
    if (baseScale <= 0) return;
    var r = ratio;
    if (baseScale * r < minScale) r = minScale / baseScale;
    if (baseScale * r > maxScale) r = maxScale / baseScale;

    final m = Matrix4.identity()
      ..translate(newFocal.dx, newFocal.dy)
      ..scale(r)
      ..translate(-baseFocal.dx, -baseFocal.dy);
    m.multiply(base);
    _set(m);
  }

  /// Centers the full page inside [size] with [margin] (initial layout +
  /// the harness "fit" button; the editor uses it in Step 5).
  void fitToPage(Size size, {double margin = 24}) {
    if (size.width <= 0 || size.height <= 0) return;
    final scale = math.max(
      minScale,
      math.min(
        maxScale,
        math.min(
          (size.width - margin * 2) / pageWidth,
          (size.height - margin * 2) / pageHeight,
        ),
      ),
    );
    final m = Matrix4.identity();
    m.setEntry(0, 0, scale);
    m.setEntry(1, 1, scale);
    m.setEntry(0, 3, (size.width - pageWidth * scale) / 2);
    m.setEntry(1, 3, (size.height - pageHeight * scale) / 2);
    _set(m);
  }
}
