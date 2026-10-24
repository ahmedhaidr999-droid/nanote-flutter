import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/database/collections/document.dart';
import '../../../core/database/collections/note_page.dart';
import 'library_repository.dart';
import '../presentation/library_prefs.dart';
import '../domain/library_models.dart';

part 'library_providers.g.dart';

/// Merged shelf snapshot (folders + documents of one folder), re-subscribed
/// when sort or quick-find query change. `folderId` = null → root shelf.
@riverpod
Stream<LibrarySnapshot> librarySnapshot(Ref ref, int? folderId) async* {
  final repo = await ref.watch(libraryRepositoryProvider.future);
  final prefs = ref.watch(libraryPrefsProvider);
  yield* repo.watchLibrary(
    folderId: folderId,
    sort: prefs.sort,
    query: prefs.searching ? prefs.effectiveQuery : null,
  );
}

/// One folder's display name (app bar while browsing it).
@riverpod
Stream<String?> folderName(Ref ref, int folderId) async* {
  final repo = await ref.watch(libraryRepositoryProvider.future);
  yield* repo.watchFolderName(folderId);
}

/// The open document, live (editor chrome reacts to renames etc.).
@riverpod
Stream<Document?> libraryDocument(Ref ref, int documentId) async* {
  final repo = await ref.watch(libraryRepositoryProvider.future);
  yield* repo.watchDocument(documentId);
}

/// Pages of the open document in reading order — the editor's virtualized
/// scroller subscribes here and nothing else.
@riverpod
Stream<List<NotePage>> documentPages(Ref ref, int documentId) async* {
  final repo = await ref.watch(libraryRepositoryProvider.future);
  yield* repo.watchPages(documentId);
}
