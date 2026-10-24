import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/database/collections/stroke.dart';
import '../../../core/database/isar_provider.dart';

part 'stroke_repository.g.dart';

/// Persistence seam consumed by the [InkController]. An interface so the
/// canvas engine runs (and is unit-testable) with ZERO database attached —
/// the dev harness draws purely in memory.
abstract class InkPersistence {
  /// Applies one stroke edit atomically. Reads stroke ids at TRANSACTION
  /// time — an earlier queued txn may only now have assigned the real id.
  Future<void> commit({
    required List<Stroke> removed,
    required List<Stroke> inserted,
  });

  /// All strokes of a page, in z-order (id ascending).
  Future<List<Stroke>> loadStrokes(int pageId);
}

@Riverpod(keepAlive: true)
Future<InkPersistence> strokeRepository(Ref ref) async {
  final isar = await ref.watch(isarProvider.future);
  return IsarStrokeRepository(isar);
}

class IsarStrokeRepository implements InkPersistence {
  IsarStrokeRepository(this._isar);

  final Isar _isar;

  @override
  Future<void> commit({
    required List<Stroke> removed,
    required List<Stroke> inserted,
  }) async {
    await _isar.writeTxn(() async {
      final ids = <int>[for (final s in removed) if (s.id > 0) s.id];
      if (ids.isNotEmpty) {
        await _isar.strokes.deleteAll(ids);
      }
      if (inserted.isNotEmpty) {
        for (final s in inserted) {
          if (s.id <= 0) s.id = Isar.autoIncrement; // local id → auto-assign
        }
        final newIds = await _isar.strokes.putAll(inserted);
        // Write real ids back onto the objects — later queued operations
        // (undo of this insert, etc.) read them at THEIR txn time.
        for (var i = 0; i < inserted.length; i++) {
          inserted[i].id = newIds[i];
        }
      }
    });
  }

  @override
  Future<List<Stroke>> loadStrokes(int pageId) async {
    final rows = await _isar.strokes.filter().pageIdEqualTo(pageId).findAll();
    rows.sort((a, b) => a.id.compareTo(b.id)); // z-order = id ascending
    return rows;
  }
}
