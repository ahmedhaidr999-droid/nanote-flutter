import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/database/collections/text_block.dart';
import '../../../core/database/isar_provider.dart';

part 'text_repository.g.dart';

/// Persistence seam for the text layer — same pattern as [InkPersistence]:
/// the layer controller runs testable with no database attached.
abstract class TextPersistence {
  /// All text blocks of a page (id ascending = z-order).
  Future<List<TextBlock>> loadBlocks(int pageId);

  /// Inserts (id ≤ 0) or updates one block; writes the real id back.
  Future<void> upsert(TextBlock block);

  Future<void> delete(int id);
}

@Riverpod(keepAlive: true)
Future<TextPersistence> textRepository(Ref ref) async {
  final isar = await ref.watch(isarProvider.future);
  return IsarTextRepository(isar);
}

class IsarTextRepository implements TextPersistence {
  IsarTextRepository(this._isar);

  final Isar _isar;

  @override
  Future<List<TextBlock>> loadBlocks(int pageId) async {
    final rows =
        await _isar.textBlocks.filter().pageIdEqualTo(pageId).findAll();
    rows.sort((a, b) => a.id.compareTo(b.id));
    return rows;
  }

  @override
  Future<void> upsert(TextBlock block) async {
    await _isar.writeTxn(() async {
      if (block.id <= 0) block.id = Isar.autoIncrement;
      block.updatedAt = DateTime.now();
      block.id = await _isar.textBlocks.put(block);
    });
  }

  @override
  Future<void> delete(int id) => _isar.textBlocks.delete(id);
}
