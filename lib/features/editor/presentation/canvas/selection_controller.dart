import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show MatrixUtils;

import '../../../../core/database/collections/stroke.dart';
import '../../domain/geometry/ink_geometry.dart';
import '../../domain/models/stroke_codec.dart';
import '../../domain/models/stroke_point.dart';
import 'ink_controller.dart';
import 'viewport_controller.dart';

enum SelectionHandle { move, rotate, topLeft, topRight, bottomLeft, bottomRight }

enum LassoPhase { idle, looping, transforming }

/// Lasso selection state machine — one controller per canvas, composing
/// [InkController] (never owning its stroke list).
///
/// Selection tracks stroke OBJECT IDENTITY (a `Set<Stroke>` with identity
/// equality), not ids: transform/recolor replace rows with new objects, and
/// the Isar repository rewrites ids asynchronously — object identity is the
/// only stable handle across "commit → async id assignment".
///
/// All mutations commit through [InkController.commitExternalEdit] as
/// ordinary [StrokeEdit]s — lasso actions are undoable by the SAME global
/// undo stack as ink and erasing, with no special cases.
///
/// Undo semantics: undoing a transform resurrects the original objects —
/// which this controller still references — so the selection follows the
/// undo naturally. Redo swaps the copies back in; the ink listener then
/// prunes the selection (documented behaviour: redo clears selection).
class SelectionController extends ChangeNotifier {
  SelectionController({required this.ink, required this.viewport}) {
    ink.addListener(_onInkChanged);
  }

  final InkController ink;
  final ViewportController viewport;

  LassoPhase phase = LassoPhase.idle;

  /// Live lasso loop points (page space) — non-empty only while looping.
  final List<Offset> loop = [];

  final Set<Stroke> _selected = {};
  bool get hasSelection => _selected.isNotEmpty;
  bool isSelected(Stroke s) => _selected.contains(s);

  /// Gesture-space matrix (page coords) while transforming; `null` outside.
  Matrix4? liveMatrix;
  bool get isTransforming =>
      phase == LassoPhase.transforming && liveMatrix != null;

  // ── Gesture snapshots ─────────────────────────────────────────────────────
  Rect? _baseBounds;
  Offset? _gestureStartPage;
  Matrix4? _gestureBaseMatrix;
  SelectionHandle? _gestureHandle;
  bool _gestureChanged = false;

  Rect? _boundsCache;
  int _lastSeenEditVersion = -1;

  static const double handleHitRadius = 26; // touch-friendly
  static const double rotateHandleGap = 36; // screen px above top-center

  @override
  void dispose() {
    ink.removeListener(_onInkChanged);
    super.dispose();
  }

  /// Prunes the selection when its strokes vanish (undo/redo/erase). Runs
  /// only when [InkController.editVersion] moved — NEVER on the 120Hz
  /// active-ink notifications.
  void _onInkChanged() {
    if (ink.editVersion == _lastSeenEditVersion) return;
    _lastSeenEditVersion = ink.editVersion;
    if (_selected.isEmpty) return;

    final sel = Set.identity()..addAll(_selected);
    final alive = <Stroke>{};
    for (final s in ink.strokes) {
      if (sel.contains(s)) alive.add(s);
    }
    if (alive.length == _selected.length) return;

    _selected
      ..clear()
      ..addAll(alive);
    _boundsCache = null;
    if (_selected.isEmpty) {
      phase = LassoPhase.idle;
      liveMatrix = null;
    }
    notifyListeners();
  }

  // ── Lasso loop ────────────────────────────────────────────────────────────

  void beginLoop(Offset pagePos) {
    _selected.clear();
    loop.clear();
    _boundsCache = null;
    liveMatrix = null;
    phase = LassoPhase.looping;
    loop.add(pagePos);
    notifyListeners();
  }

  void extendLoop(Offset pagePos) {
    if (phase != LassoPhase.looping) return;
    final last = loop.isEmpty ? null : loop.last;
    if (last == null || (pagePos - last).distance > 2) {
      loop.add(pagePos);
      notifyListeners();
    }
  }

  /// Closes the loop and resolves the selection: a stroke is selected when
  /// ANY of its points lies inside the polygon OR the loop CROSSES the
  /// stroke (sparse straight strokes whose endpoints sit outside).
  void endLoop() {
    if (phase != LassoPhase.looping) return;
    phase = LassoPhase.idle;

    if (loop.length >= 3) {
      final poly = List<Offset>.of(loop);
      final polyBounds = polygonBounds(poly);

      for (final s in ink.strokes) {
        final box = Rect.fromLTRB(s.minX, s.minY, s.maxX, s.maxY);
        if (!box.inflate(s.baseWidth).overlaps(polyBounds)) continue;

        final pts = s.readPoints();
        var hit = false;
        for (final p in pts) {
          if (pointInPolygon(p.position, poly)) {
            hit = true;
            break;
          }
        }
        if (!hit) {
          for (var i = 0; i + 1 < pts.length && !hit; i++) {
            hit = segmentIntersectsPolygon(
                pts[i].position, pts[i + 1].position, poly);
          }
        }
        if (hit) _selected.add(s);
      }
    }

    loop.clear();
    _boundsCache = null;
    notifyListeners();
  }

  // ── Selection geometry ────────────────────────────────────────────────────

  /// Current AABB of the selection (page space), including the live
  /// transform when one is active.
  Rect selectionBounds() {
    var cached = _boundsCache;
    if (cached == null) {
      if (_selected.isEmpty) return Rect.zero;
      var minX = double.infinity, minY = double.infinity;
      var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
      for (final s in _selected) {
        if (s.minX < minX) minX = s.minX;
        if (s.minY < minY) minY = s.minY;
        if (s.maxX > maxX) maxX = s.maxX;
        if (s.maxY > maxY) maxY = s.maxY;
      }
      cached = Rect.fromLTRB(minX, minY, maxX, maxY);
      _boundsCache = cached;
    }

    final m = liveMatrix;
    if (m == null) return cached;

    final corners = [
      cached.topLeft, cached.topRight, cached.bottomLeft, cached.bottomRight,
    ].map((p) => MatrixUtils.transformPoint(m, p));
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final c in corners) {
      if (c.dx < minX) minX = c.dx;
      if (c.dy < minY) minY = c.dy;
      if (c.dx > maxX) maxX = c.dx;
      if (c.dy > maxY) maxY = c.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  // ── Hit testing (screen space) ────────────────────────────────────────────

  /// Returns the handle under [screenPos] (canvas-local px), if any.
  /// Handles render at CONSTANT screen size regardless of zoom — a 500%
  /// zoom must not turn a grab handle into a continent.
  SelectionHandle? hitTestHandle(Offset screenPos) {
    if (!hasSelection || isTransforming) return null;
    final b = selectionBounds();

    Offset sp(Offset p) => viewport.pageToScreen(p);
    final tl = sp(b.topLeft);
    final tr = sp(b.topRight);
    final bl = sp(b.bottomLeft);
    final br = sp(b.bottomRight);
    final rot = sp(Offset(b.center.dx, b.top)) + const Offset(0, -rotateHandleGap);

    bool near(Offset p) => (screenPos - p).distance <= handleHitRadius;
    if (near(tl)) return SelectionHandle.topLeft;
    if (near(tr)) return SelectionHandle.topRight;
    if (near(br)) return SelectionHandle.bottomRight;
    if (near(bl)) return SelectionHandle.bottomLeft;
    if (near(rot)) return SelectionHandle.rotate;
    return null;
  }

  /// Loose inside test for initiating a move-drag.
  bool hitTestSelection(Offset pagePos) =>
      hasSelection && selectionBounds().inflate(12).contains(pagePos);

  // ── Transform gesture ─────────────────────────────────────────────────────

  void beginTransform(SelectionHandle handle, Offset screenPos) {
    if (!hasSelection) return;
    _baseBounds = selectionBounds();
    _gestureStartPage = viewport.screenToPage(screenPos);
    _gestureBaseMatrix = (liveMatrix ?? Matrix4.identity()).clone();
    _gestureHandle = handle;
    _gestureChanged = false;
    phase = LassoPhase.transforming;
    liveMatrix = Matrix4.copy(_gestureBaseMatrix!);
    notifyListeners();
  }

  void updateTransform(Offset screenPos) {
    if (phase != LassoPhase.transforming) return;
    final base = _gestureBaseMatrix!;
    final start = _gestureStartPage!;
    final b = _baseBounds!;
    final p = viewport.screenToPage(screenPos);

    late final Matrix4 op;
    switch (_gestureHandle!) {
      case SelectionHandle.move:
        op = Matrix4.identity()
          ..translate((p - start).dx, (p - start).dy);

      case SelectionHandle.rotate:
        final pivot = b.center;
        final a0 = math.atan2(start.dy - pivot.dy, start.dx - pivot.dx);
        final a1 = math.atan2(p.dy - pivot.dy, p.dx - pivot.dx);
        op = Matrix4.identity()
          ..translate(pivot.dx, pivot.dy)
          ..rotateZ(a1 - a0)
          ..translate(-pivot.dx, -pivot.dy);

      case SelectionHandle.topLeft:
      case SelectionHandle.topRight:
      case SelectionHandle.bottomLeft:
      case SelectionHandle.bottomRight:
        // Uniform resize about the ANCHOR (opposite corner) — the anchor
        // stays pixel-locked while the dragged corner follows the pointer.
        final anchor = switch (_gestureHandle!) {
          SelectionHandle.topLeft => b.bottomRight,
          SelectionHandle.topRight => b.bottomLeft,
          SelectionHandle.bottomLeft => b.topRight,
          SelectionHandle.bottomRight => b.topLeft,
          _ => b.center,
        };
        final d0 = (start - anchor).distance;
        final d1 = (p - anchor).distance;
        var s = d0 > 1e-6 ? d1 / d0 : 1.0;
        if (s.isNaN || s.isInfinite) s = 1.0;
        s = s.clamp(0.05, 20.0);
        op = Matrix4.identity()
          ..translate(anchor.dx, anchor.dy)
          ..scale(s)
          ..translate(-anchor.dx, -anchor.dy);
    }

    // Gesture ops compose LEFT-multiplied onto the gesture-start matrix:
    // the whole gesture is one matrix against the ORIGINAL geometry.
    final m = Matrix4.copy(op)..multiply(base);
    _gestureChanged = true;
    liveMatrix = m;
    notifyListeners();
  }

  void endTransform() {
    if (phase != LassoPhase.transforming) return;
    final m = liveMatrix;
    final changed = _gestureChanged;
    phase = LassoPhase.idle;
    liveMatrix = null;
    _gestureHandle = null;
    if (changed && m != null) _commitTransform(m);
    notifyListeners();
  }

  /// Aborts the active gesture without committing (second finger arrived,
  /// pointer cancel).
  void cancelGesture() {
    if (phase == LassoPhase.looping) {
      loop.clear();
      phase = LassoPhase.idle;
    } else if (phase == LassoPhase.transforming) {
      liveMatrix = null;
      phase = LassoPhase.idle;
      _gestureHandle = null;
    }
    notifyListeners();
  }

  void _commitTransform(Matrix4 m) {
    final removed = _selected.toList();
    final inserted = <Stroke>[];
    for (final s in removed) {
      final pts = s.readPoints()
          .map((sp) => StrokePoint(MatrixUtils.transformPoint(m, sp.position), sp.pressure))
          .toList(growable: false);
      inserted.add(strokeFromPoints(
        pageId: s.pageId,
        tool: s.tool,
        colorValue: s.colorValue,
        baseWidth: s.baseWidth,
        styleValue: s.styleValue,
        opacity: s.opacity,
        points: pts,
      )..id = ink.nextLocalId());
    }
    ink.commitExternalEdit(StrokeEdit(removed: removed, inserted: inserted));
    _selected
      ..clear()
      ..addAll(inserted);
    _boundsCache = null;
  }

  // ── Immediate edits ───────────────────────────────────────────────────────

  /// Recolors the whole selection (geometry copied verbatim — no re-decode).
  void recolor(int colorValue) {
    if (_selected.isEmpty || isTransforming) return;
    final removed = _selected.toList();
    final inserted = <Stroke>[
      for (final s in removed)
        Stroke()
          ..id = ink.nextLocalId()
          ..pageId = s.pageId
          ..tool = s.tool
          ..colorValue = colorValue
          ..baseWidth = s.baseWidth
          ..styleValue = s.styleValue
          ..opacity = s.opacity
          ..coords = List<double>.of(s.coords)
          ..minX = s.minX
          ..minY = s.minY
          ..maxX = s.maxX
          ..maxY = s.maxY
          ..createdAt = s.createdAt,
    ];
    ink.commitExternalEdit(StrokeEdit(removed: removed, inserted: inserted));
    _selected
      ..clear()
      ..addAll(inserted);
    _boundsCache = null;
    notifyListeners();
  }

  void deleteSelection() {
    if (_selected.isEmpty) return;
    ink.commitExternalEdit(
      StrokeEdit(removed: _selected.toList(growable: false), inserted: const []),
    );
    _clearQuiet();
    notifyListeners();
  }

  void clear() {
    if (_selected.isEmpty && loop.isEmpty && liveMatrix == null) {
      phase = LassoPhase.idle;
      return;
    }
    _clearQuiet();
    notifyListeners();
  }

  void _clearQuiet() {
    _selected.clear();
    loop.clear();
    _boundsCache = null;
    liveMatrix = null;
    _gestureHandle = null;
    phase = LassoPhase.idle;
  }
}
