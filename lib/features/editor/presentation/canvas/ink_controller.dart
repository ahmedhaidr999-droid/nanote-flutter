import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/database/collections/stroke.dart';
import '../../data/stroke_repository.dart';
import '../../domain/geometry/ink_geometry.dart';
import '../../domain/models/stroke_codec.dart';
import '../../domain/models/stroke_point.dart';
import '../../domain/models/tools.dart';

/// A mutation of the committed stroke set. Drawing and erasing BOTH reduce
/// to this shape, which is what makes undo/redo uniform:
///
///     draw  = (removed: ∅,        inserted: [stroke])
///     erase = (removed: [origs],  inserted: [split pieces])
@immutable
class StrokeEdit {
  const StrokeEdit({required this.removed, required this.inserted});

  final List<Stroke> removed;
  final List<Stroke> inserted;
}

/// Live (not yet committed) ink under the pointer. The Isar [Stroke] row is
/// only materialized at pen-up — the hot path stays allocation-light and
/// the DB is touched once per stroke.
@immutable
class ActiveInk {
  const ActiveInk({
    required this.pageId,
    required this.tool,
    required this.colorValue,
    required this.baseWidth,
    required this.styleValue,
    required this.opacity,
    required this.points,
  });

  final int pageId;
  final InkTool tool;
  final int colorValue;
  final double baseWidth;

  /// [PenStyle] ordinal — the renderer branches on it while the stroke is
  /// live, exactly like committed ink.
  final int styleValue;
  final double opacity;

  final List<StrokePoint> points;

  Offset get lastPosition => points.last.position;
}

/// Composes two sequential edits into their net effect. Critical detail: a
/// stroke split twice within ONE eraser gesture must not resurrect its
/// intermediate pieces on redo — later removals cancel earlier insertions.
StrokeEdit composeEdits(StrokeEdit a, StrokeEdit b) {
  final removed = List<Stroke>.of(a.removed);
  final inserted = List<Stroke>.of(a.inserted);
  for (final s in b.removed) {
    if (inserted.contains(s)) {
      inserted.remove(s); // inserted then removed within the gesture → net nothing
    } else {
      removed.add(s);
    }
  }
  for (final s in b.inserted) {
    if (!inserted.contains(s)) inserted.add(s);
  }
  return StrokeEdit(removed: removed, inserted: inserted);
}

/// Hot-path ink state for one page.
///
/// Intentionally a plain [ChangeNotifier], NOT a Riverpod provider: pointer
/// events arrive at 120Hz+ and must never rebuild a widget tree — painters
/// attach to this via `CustomPainter(repaint: …)` and repaint straight from
/// the notification. Riverpod governs the COLD state (tool palette).
///
/// Performance contract:
///  • committed strokes tessellate ONCE (Expando cache keyed by object
///    identity — entries die with their stroke, no invalidation bookkeeping);
///  • only the active stroke re-tessellates per frame;
///  • pen-up = one Isar row; erasing = one small txn per gesture.
class InkController extends ChangeNotifier {
  InkController({
    InkPersistence? persistence,
    this.pageId = 0,
    this.maxUndoDepth = 100,
  }) : _persistence = persistence;

  final InkPersistence? _persistence;
  final int pageId;
  final int maxUndoDepth;

  /// Committed strokes in z-order (ascending id).
  final List<Stroke> strokes = [];

  ActiveInk? activeInk;
  bool get isDrawing => activeInk != null;

  final List<StrokeEdit> _undoStack = [];
  final List<StrokeEdit> _redoStack = [];
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  final Expando<InkOutline> _outlineCache = Expando<InkOutline>();

  /// Bumped on every COMMITTED change (draw, edit, undo, hydrate) — NOT on
  /// 120Hz active-ink notifications. Lets the selection controller prune
  /// itself without paying per-frame cost.
  int editVersion = 0;

  /// Tessellated outline of a committed stroke (cached on first request).
  /// Highlighter strokes tessellate as constant-width bands; pen strokes
  /// honor their [PenStyle] profile (taper / speed / calligraphy).
  InkOutline outlineOf(Stroke s) => _outlineCache[s] ??= InkOutlineBuilder.build(
        s.readPoints(),
        s.baseWidth,
        constantWidth: s.tool == InkTool.highlighter,
        style: s.tool == InkTool.highlighter ? PenStyle.regular : s.penStyle,
      );

  // ── Hydration ────────────────────────────────────────────────────────────

  /// Loads the page's strokes from persistence (editor open, Step 5).
  Future<void> hydrate() async {
    final p = _persistence;
    if (p == null) return;
    final loaded = await p.loadStrokes(pageId);
    strokes
      ..clear()
      ..addAll(loaded);
    editVersion++;
    notifyListeners();
  }

  // ── Serialized DB queue ──────────────────────────────────────────────────

  /// All persistence flows through one serialized chain — ordering matters:
  /// a stroke inserted and then undone before its txn lands must never
  /// resurrect as a ghost row on next launch. Ids are read at TRANSACTION
  /// time (an earlier txn may only now have assigned the real id).
  Future<void> _dbQueue = Future<void>.value();

  void _enqueueCommit(StrokeEdit edit) {
    final p = _persistence;
    if (p == null) return;
    final removed = List<Stroke>.of(edit.removed);
    final inserted = List<Stroke>.of(edit.inserted);
    _dbQueue = _dbQueue
        .then<void>((_) => p.commit(removed: removed, inserted: inserted))
        .catchError((Object e) => debugPrint('nanote: stroke persistence error: $e'));
  }

  // ── Drawing ──────────────────────────────────────────────────────────────

  /// Minimum spacing between recorded points (page pts) — sheds pointer
  /// jitter and keeps rows compact without visible quality loss.
  static const double _minPointDistance = 1.0;

  void beginStroke(Offset pagePos, double pressure, ToolPaletteState tool) {
    if (activeInk != null) return;
    final isHighlighter = tool.tool == ToolType.highlighter;
    activeInk = ActiveInk(
      pageId: pageId,
      tool: isHighlighter ? InkTool.highlighter : InkTool.pen,
      colorValue: (isHighlighter ? tool.highlighterColor : tool.penColor).value,
      baseWidth: isHighlighter ? tool.highlighterSize : tool.penSize,
      styleValue: isHighlighter ? 0 : tool.penStyle.index,
      opacity: isHighlighter ? 1.0 : tool.penOpacity,
      points: <StrokePoint>[StrokePoint(pagePos, _clampPressure(pressure))],
    );
    notifyListeners();
  }

  void appendPoint(Offset pagePos, double pressure) {
    final a = activeInk;
    if (a == null) return;
    if ((pagePos - a.lastPosition).distance < _minPointDistance) return;
    a.points.add(StrokePoint(pagePos, _clampPressure(pressure)));
    notifyListeners();
  }

  void cancelStroke() {
    if (activeInk == null) return;
    activeInk = null;
    notifyListeners();
  }

  /// Pen-up: materialize the row, keep z-order, push the undo entry,
  /// enqueue exactly one DB write.
  void endStroke() {
    final a = activeInk;
    activeInk = null;
    if (a == null || a.points.isEmpty) {
      notifyListeners();
      return;
    }
    final stroke = strokeFromPoints(
      pageId: a.pageId,
      tool: a.tool,
      colorValue: a.colorValue,
      baseWidth: a.baseWidth,
      styleValue: a.styleValue,
      opacity: a.opacity,
      points: a.points,
    )..id = nextLocalId();
    strokes.add(stroke);
    _pushEdit(StrokeEdit(removed: const <Stroke>[], inserted: <Stroke>[stroke]));
    editVersion++;
    notifyListeners();
  }

  int _localIdCounter = 0;

  /// Negative ids never collide with Isar's autoincrement; the repository
  /// rewrites them to real ids inside its txn.
  int nextLocalId() => --_localIdCounter;

  // ── Shapes (Notewise shape tool) ───────────────────────────────────

  /// Ghost (uncommitted) shape strokes while the shape gesture is live.
  /// Rendered by [InkPainter] exactly like committed ink; rebuilt each
  /// pointer move (object identity changes — the Expando outline cache is
  /// keyed by identity, so ghosts never poison it).
  List<Stroke> shapePreview = const [];

  /// Live shape gesture: replaces the ghost set with [polylines] sampled
  /// by [sampleShape]. Arrow heads arrive as extra polylines and preview
  /// (and later commit) together as ONE shape.
  void previewShape(
    List<List<StrokePoint>> polylines,
    ToolPaletteState tool,
  ) {
    shapePreview = [
      for (final pl in polylines)
        strokeFromPoints(
          pageId: pageId,
          tool: InkTool.shape,
          colorValue: tool.penColor.value,
          baseWidth: tool.shapeSize,
          opacity: tool.penOpacity,
          points: pl,
        )..id = nextLocalId(),
    ];
    notifyListeners();
  }

  /// Pen-up on a shape: all ghost strokes commit as ONE edit — one undo
  /// step removes (or restores) the whole shape, arrow head included.
  void endShape() {
    final ghosts = shapePreview;
    shapePreview = const [];
    if (ghosts.isEmpty) {
      notifyListeners();
      return;
    }
    strokes.addAll(ghosts);
    _pushEdit(StrokeEdit(removed: const <Stroke>[], inserted: ghosts));
    editVersion++;
    notifyListeners();
  }

  void cancelShape() {
    if (shapePreview.isEmpty) return;
    shapePreview = const [];
    notifyListeners();
  }

  // ── Erasing ──────────────────────────────────────────────────────────────

  Offset? _lastErasePos;
  StrokeEdit? _pendingErase;

  void beginErase(Offset pagePos) {
    _lastErasePos = pagePos;
    _pendingErase = null;
  }

  /// Applies the eraser capsule from the previous sample to [pagePos].
  /// In-memory state updates immediately (UI feedback); persistence is
  /// composed and flushed once per gesture in [endErase].
  void eraseSegment(Offset pagePos, double diameter, EraserMode mode) {
    final from = _lastErasePos ?? pagePos;
    _lastErasePos = pagePos;
    if (strokes.isEmpty) return;

    final radius = diameter / 2;
    final capsule = Rect.fromPoints(from, pagePos).inflate(radius);

    final removed = <Stroke>[];
    final inserted = <Stroke>[];

    for (final s in strokes) {
      // O(1) bbox prefilter — point lists are only decoded on overlap.
      final strokeBox = Rect.fromLTRB(s.minX, s.minY, s.maxX, s.maxY)
          .inflate(radius + s.baseWidth);
      if (!capsule.overlaps(strokeBox)) continue;

      final pts = s.readPoints();

      if (mode == EraserMode.stroke) {
        var hit = false;
        for (final p in pts) {
          if (distanceToSegment(p.position, from, pagePos) < radius) {
            hit = true;
            break;
          }
        }
        if (hit) removed.add(s);
      } else {
        final runs = splitByEraserCapsule(pts, from, pagePos, radius);
        if (runs == null) continue;
        removed.add(s);
        for (final run in runs) {
          inserted.add(strokeFromPoints(
            pageId: s.pageId,
            tool: s.tool,
            colorValue: s.colorValue,
            baseWidth: s.baseWidth,
            styleValue: s.styleValue,
            opacity: s.opacity,
            points: run,
          )..id = nextLocalId());
        }
      }
    }

    if (removed.isEmpty) return;

    _applyEdit(StrokeEdit(removed: removed, inserted: inserted), persist: false);
    _pendingErase = _pendingErase == null
        ? StrokeEdit(removed: removed, inserted: inserted)
        : composeEdits(_pendingErase!, StrokeEdit(removed: removed, inserted: inserted));
  }

  void endErase() {
    final e = _pendingErase;
    _pendingErase = null;
    _lastErasePos = null;
    if (e == null) return;
    _pushEdit(e); // one composed txn per gesture
  }

  // ── Undo / redo / external edits ──────────────────────────────────────────

  /// Applies + persists an edit produced OUTSIDE this controller (lasso
  /// move/resize/rotate/recolor/delete). Same undo stack, same DB queue —
  /// selection ops are indistinguishable from any other edit.
  void commitExternalEdit(StrokeEdit e) => _pushEdit(e);

  void _pushEdit(StrokeEdit e) {
    _undoStack.add(e);
    if (_undoStack.length > maxUndoDepth) _undoStack.removeAt(0);
    _redoStack.clear();
    _enqueueCommit(e);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final e = _undoStack.removeLast();
    _redoStack.add(e);
    _applyEdit(StrokeEdit(removed: e.inserted, inserted: e.removed), persist: true);
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    final e = _redoStack.removeLast();
    _undoStack.add(e);
    _applyEdit(e, persist: true);
  }

  /// Applies [e] to the in-memory list. Split pieces are re-inserted at the
  /// ORIGINAL z-position of the stroke they replace (not floated to top) —
  /// pixel-erasing must not shuffle ink above neighbouring strokes.
  void _applyEdit(StrokeEdit e, {required bool persist}) {
    if (e.removed.isEmpty && e.inserted.isEmpty) return;
    var insertAt = strokes.length;
    for (final r in e.removed) {
      final idx = strokes.indexOf(r);
      if (idx < 0) continue;
      strokes.removeAt(idx);
      if (idx < insertAt) insertAt = idx;
    }
    if (e.inserted.isNotEmpty) strokes.insertAll(insertAt, e.inserted);
    if (persist) _enqueueCommit(e);
    editVersion++;
    notifyListeners();
  }

  static double _clampPressure(double p) {
    if (p < 0) return 0;
    if (p > 1 || p.isNaN) return 1;
    return p;
  }
}
