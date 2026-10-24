import 'package:flutter/material.dart';

/// One sampled input point of a stroke, in PAGE coordinates.
///
/// Deliberately a hand-written immutable class (not freezed): the drawing
/// hot path allocates thousands of these per stroke — a const constructor
/// with zero codegen indirection keeps that cheap.
class StrokePoint {
  const StrokePoint(this.position, this.pressure);

  final Offset position;

  /// 0..1 — stylus pressure; mouse/finger fallback is 0.5.
  final double pressure;
}
