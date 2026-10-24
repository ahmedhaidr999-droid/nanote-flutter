import 'package:isar/isar.dart';

part 'stroke.g.dart';

/// Which tool produced the ink. (Ordinal storage — append-only.)
/// `shape` strokes render as stroked polylines (crisp geometry) instead of
/// pressure outlines — see [InkPainter].
enum InkTool { pen, highlighter, shape }

/// One vector stroke — the atomic unit of Nanote ink.
///
/// Storage layout:
///  • Geometry lives in [coords] as flattened `x, y, pressure` triples in
///    PAGE coordinates (logical points). A primitive double list serializes
///    far faster than nested objects and is rebuilt into runtime points by
///    `StrokeCodec` in a single pass.
///  • Z-order = [id] ascending (insertion order). All draw loops rely on it.
///  • The denormalized bounding box makes painter culling, eraser
///    hit-testing and (Step 3) lasso selection O(1) to prefilter — point
///    lists are never touched unless a bbox intersects.
///
/// Pen-up appends exactly ONE row: O(1) writes regardless of page length.
@collection
class Stroke {
  Id id = Isar.autoIncrement;

  /// Owning page.
  @Index()
  int pageId = 0;

  @enumerated
  InkTool tool = InkTool.pen;

  int colorValue = 0xFF155EEF;
  double baseWidth = 2.6;

  List<double> coords = const [];

  // Denormalized bbox (page coords) — see class docs.
  double minX = 0;
  double minY = 0;
  double maxX = 0;
  double maxY = 0;

  DateTime createdAt = DateTime.now();
}
