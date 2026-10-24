import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'collections/document.dart';
import 'collections/folder.dart';
import 'collections/note_page.dart';
import 'collections/stroke.dart';

part 'isar_provider.g.dart';

/// Process-wide Isar instance.
///
/// • keepAlive: the database outlives navigation — it must never close while
///   features still hold queries, and must never be opened twice.
/// • Additive schema changes (e.g. `StrokeSchema` in Step 2) are applied
///   automatically by Isar on open — no manual migrations needed.
@Riverpod(keepAlive: true)
Future<Isar> isar(Ref ref) async {
  final dir = await getApplicationDocumentsDirectory();

  final isar = await Isar.open(
    [
      FolderSchema,
      DocumentSchema,
      NotePageSchema,
      StrokeSchema, // ← vector ink (Step 2)
    ],
    directory: dir.path,
    name: 'nanote',
    inspector: kDebugMode,
  );

  ref.onDispose(() => isar.close());

  return isar;
}
