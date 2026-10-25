import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/database/collections/text_block.dart';
import '../../data/text_repository.dart';

/// Hot-path text-layer state for one page — the text-tool twin of
/// [InkController]: a plain ChangeNotifier the painters repaint from.
///
/// Text blocks are deliberately NOT part of the ink undo stack in this
/// iteration; their lifecycle (create / edit / move / delete) is owned by
/// the text tool itself, with persistence flushed per action.
class TextLayerController extends ChangeNotifier {
  TextLayerController({TextPersistence? persistence, this.pageId = 0})
      : _persistence = persistence;

  final TextPersistence? _persistence;
  final int pageId;

  /// Committed blocks in z-order (id ascending).
  final List<TextBlock> blocks = [];

  /// The block currently being dragged by the text tool (draws a frame).
  TextBlock? activeDragBlock;

  // ── Measurement cache ───────────────────────────────────────────────────
  //
  // Layout depends on (content, fontSize) only — cache the size per block
  // and re-measure when either changes. Pages hold a handful of text
  // boxes; a plain map is plenty.
  final Map<int, _MeasuredText> _measured = {};

  Size measureOf(TextBlock b) {
    final cached = _measured[b.id];
    if (cached != null &&
        cached.content == b.content &&
        cached.fontSize == b.fontSize) {
      return cached.size;
    }
    final tp = TextPainter(
      text: TextSpan(
        text: b.content.isEmpty ? ' ' : b.content,
        style: TextStyle(
          fontSize: b.fontSize,
          height: 1.28,
          color: Color(b.colorValue),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final size = tp.size;
    _measured[b.id] = _MeasuredText(b.content, b.fontSize, size);
    return size;
  }

  Rect blockRect(TextBlock b) =>
      Offset(b.x, b.y) & measureOf(b);

  /// Topmost block containing [pagePoint] (null when none).
  TextBlock? blockAt(Offset pagePoint) {
    for (final b in blocks.reversed) {
      if (blockRect(b).inflate(4).contains(pagePoint)) return b;
    }
    return null;
  }

  // ── Hydration ────────────────────────────────────────────────────────────

  Future<void> hydrate() async {
    final p = _persistence;
    if (p == null) return;
    final loaded = await p.loadBlocks(pageId);
    blocks
      ..clear()
      ..addAll(loaded);
    _measured.clear();
    notifyListeners();
  }

  // ── Mutations (each flushes its own row — no batching needed at human
  //    text-editing rates) ──────────────────────────────────────────────────

  /// In-memory move during a drag (no notify per micro-delta is fine at
  /// 120Hz — the painter repaints from `notifyListeners`).
  void moveBlockBy(TextBlock b, Offset pageDelta) {
    b.x += pageDelta.dx;
    b.y += pageDelta.dy;
    activeDragBlock = b;
    notifyListeners();
  }

  /// Persists a block after a drag/edit (upsert; real id lands in-place).
  Future<void> persistBlock(TextBlock b) async {
    activeDragBlock = null;
    notifyListeners();
    final p = _persistence;
    if (p == null) return;
    try {
      await p.upsert(b);
    } catch (e) {
      debugPrint('nanote: text persist failed: $e');
    }
    notifyListeners();
  }

  /// Creates a new block anchored at [at] (page coords) — the sheet's
  /// Save commits the content; an empty draft is never kept.
  Future<TextBlock> createBlock(
    Offset at, {
    required String content,
    required double fontSize,
    required int colorValue,
    int stickyColorValue = 0,
  }) async {
    final b = TextBlock()
      ..pageId = pageId
      ..x = at.dx
      ..y = at.dy
      ..content = content
      ..fontSize = fontSize
      ..colorValue = colorValue
      ..stickyColorValue = stickyColorValue;
    blocks.add(b);
    notifyListeners();
    await persistBlock(b);
    return b;
  }

  /// Removes a block from the layer and the DB.
  Future<void> removeBlock(TextBlock b) async {
    blocks.remove(b);
    _measured.remove(b.id);
    if (activeDragBlock == b) activeDragBlock = null;
    notifyListeners();
    final p = _persistence;
    if (p == null) return;
    try {
      if (b.id > 0) await p.delete(b.id);
    } catch (e) {
      debugPrint('nanote: text delete failed: $e');
    }
  }

  @override
  void dispose() {
    _measured.clear();
    super.dispose();
  }
}

class _MeasuredText {
  const _MeasuredText(this.content, this.fontSize, this.size);

  final String content;
  final double fontSize;
  final Size size;
}
