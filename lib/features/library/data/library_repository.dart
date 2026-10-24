import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/database/collections/document.dart';
import '../../../core/database/collections/folder.dart';
import '../../../core/database/collections/note_page.dart';
import '../../../core/database/isar_provider.dart';
import '../../../core/utils/path_helpers.dart';
import '../domain/library_models.dart';

part 'library_repository.g.dart';

@Riverpod(keepAlive: true)
Future<LibraryRepository> libraryRepository(Ref ref) async {
  final isar = await ref.watch(isarProvider.future);
  return LibraryRepository(isar);
}

/// Every shelf / document mutation in one place. The UI never touches Isar
/// directly — it watches streams and calls intent-named methods here.
///
/// Index contract (Step 1): `(folderId, updatedAt)` drives the default
/// "documents in a folder, newest first" query; `title` is value-indexed for
/// name sort / search. Pinned-first partitioning happens in Dart (stable,
/// O(n) — folders hold hundreds, not millions, of items).
class LibraryRepository {
  LibraryRepository(this._isar);

  final Isar _isar;

  // ── Watching ──────────────────────────────────────────────────────────────

  /// Folders on one shelf, in manual order then name.
  Stream<List<Folder>> watchFolders(int? parentId) {
    final q = _isar.folders.filter();
    final builder = parentId == null
        ? q.parentIdIsNull()
        : q.parentIdEqualTo(parentId);
    return builder
        .sortBySortIndex()
        .thenByName()
        .watch(fireImmediately: true);
  }

  /// Documents on one shelf, pinned first. A non-empty [query] switches to
  /// GLOBAL quick-find: the folder scope is dropped and title matching
  /// (case-insensitive) takes over.
  Stream<List<Document>> watchDocuments({
    required int? folderId,
    required LibrarySort sort,
    String? query,
  }) {
    final needle = query?.trim() ?? '';
    final searching = needle.isNotEmpty;

    final q = _isar.documents.filter();
    var builder = searching
        ? q.titleContains(needle, caseSensitive: false)
        : folderId == null
            ? q.folderIdIsNull()
            : q.folderIdEqualTo(folderId);

    final sorted = searching || sort == LibrarySort.updated
        ? builder.sortByUpdatedAtDesc()
        : builder.sortByTitle().thenByUpdatedAtDesc();

    return sorted
        .watch(fireImmediately: true)
        .map(_pinnedFirst);
  }

  static List<Document> _pinnedFirst(List<Document> rows) {
    if (rows.every((d) => !d.pinned)) return rows;
    // Splitting preserves the index-driven order within each group.
    return [
      ...rows.where((d) => d.pinned),
      ...rows.where((d) => !d.pinned),
    ];
  }

  /// Merged folders+documents stream. Manual merge (no extra dep): each
  /// side re-emits the latest pair, so both watches share one snapshot.
  Stream<LibrarySnapshot> watchLibrary({
    required int? folderId,
    required LibrarySort sort,
    String? query,
  }) {
    late StreamController<LibrarySnapshot> controller;
    var folders = const <Folder>[];
    var documents = const <Document>[];
    StreamSubscription<List<Folder>>? foldersSub;
    StreamSubscription<List<Document>>? documentsSub;

    controller = StreamController<LibrarySnapshot>(
      onListen: () {
        void emit() => controller.add(
              LibrarySnapshot(folders: folders, documents: documents),
            );
        foldersSub = watchFolders(folderId).listen(
          (f) {
            folders = f;
            emit();
          },
          onError: controller.addError,
        );
        documentsSub = watchDocuments(
          folderId: folderId,
          sort: sort,
          query: query,
        ).listen(
          (d) {
            documents = d;
            emit();
          },
          onError: controller.addError,
        );
      },
      onCancel: () async {
        await foldersSub?.cancel();
        await documentsSub?.cancel();
      },
    );

    // NOTE: while quick-find is active the stream still carries folders —
    // the home screen simply doesn't render them (search is global, shelf
    // context would be misleading).
    return controller.stream;
  }

  /// Title of one folder (app bar while inside it). Emits null if deleted.
  Stream<String?> watchFolderName(int folderId) => _isar.folders
      .filter()
      .idEqualTo(folderId)
      .watch(fireImmediately: true)
      .map((rows) => rows.isEmpty ? null : rows.first.name);

  Stream<Document?> watchDocument(int id) => _isar.documents
      .filter()
      .idEqualTo(id)
      .watch(fireImmediately: true)
      .map((rows) => rows.isEmpty ? null : rows.first);

  /// Pages of a document in reading order (composite (documentId, index)).
  Stream<List<NotePage>> watchPages(int documentId) => _isar.notePages
      .filter()
      .documentIdEqualTo(documentId)
      .sortByIndex()
      .watch(fireImmediately: true);

  // ── Folders ────────────────────────────────────────────────────────────────

  Future<Folder> createFolder({required int? parentId, required String name}) async {
    final trimmed = name.trim();
    final folder = Folder()
      ..parentId = parentId
      ..name = trimmed.isEmpty ? 'New folder' : trimmed;
    folder.id = await _isar.writeTxn(() => _isar.folders.put(folder));
    return folder;
  }

  Future<void> renameFolder(Folder folder, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    folder
      ..name = trimmed
      ..updatedAt = DateTime.now();
    await _isar.writeTxn(() => _isar.folders.put(folder));
  }

  /// Moves [folder] under [newParentId] (`null` → root). Rejects moving a
  /// folder into ITSELF or any of its own descendants — cheap ancestor walk.
  Future<bool> moveFolder(Folder folder, int? newParentId) async {
    if (newParentId == folder.id) return false;
    if (newParentId != null) {
      var cursor = newParentId;
      while (cursor != null) {
        if (cursor == folder.id) return false;
        final row = await _isar.folders.get(cursor);
        cursor = row?.parentId;
      }
    }
    folder
      ..parentId = newParentId
      ..updatedAt = DateTime.now();
    await _isar.writeTxn(() => _isar.folders.put(folder));
    return true;
  }

  /// Recursively deletes [folder], every descendant folder, every document
  /// inside any of them (with their pages, strokes and files).
  Future<void> deleteFolder(Folder folder) async {
    // Collect the subtree (iterative DFS; seen-set guards corrupt cycles).
    final toVisit = <Folder>[folder];
    final seen = <int>{folder.id};
    final subtree = <Folder>[folder];
    while (toVisit.isNotEmpty) {
      final f = toVisit.removeLast();
      final children =
          await _isar.folders.filter().parentIdEqualTo(f.id).findAll();
      for (final child in children) {
        if (seen.add(child.id)) {
          subtree.add(child);
          toVisit.add(child);
        }
      }
    }

    final folderIds = subtree.map((f) => f.id).toList(growable: false);
    final docs = await _isar.documents
        .filter()
        .anyOf(folderIds, (q, int id) => q.folderIdEqualTo(id))
        .findAll();

    for (final doc in docs) {
      await deleteDocument(doc);
    }
    await _isar.writeTxn(() => _isar.folders.deleteAllByIds(folderIds));
  }

  /// All folders (move picker tree). Name order for stable tree display.
  Future<List<Folder>> allFolders() =>
      _isar.folders.filter().sortByName().findAll();

  // ── Documents ──────────────────────────────────────────────────────────────

  /// A new blank notebook: Document + its first A4 page, one transaction.
  Future<Document> createNotebook({
    required int? folderId,
    required String title,
    required PaperTemplate template,
    required PaperShade shade,
  }) async {
    final now = DateTime.now();
    final trimmed = title.trim();
    final doc = Document()
      ..title = trimmed.isEmpty ? 'Notebook' : trimmed
      ..folderId = folderId
      ..type = DocumentType.notebook
      ..paperTemplate = template
      ..paperShade = shade
      ..pageCount = 1
      ..createdAt = now
      ..updatedAt = now;
    final firstPage = NotePage()
      ..documentId = -1 // assigned inside the txn
      ..index = 0
      ..width = 595.28
      ..height = 841.89;

    await _isar.writeTxn(() async {
      final docId = await _isar.documents.put(doc);
      firstPage.documentId = docId;
      await _isar.notePages.put(firstPage);
    });
    return doc;
  }

  Future<void> renameDocument(Document doc, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    doc
      ..title = trimmed
      ..updatedAt = DateTime.now();
    await _isar.writeTxn(() => _isar.documents.put(doc));
  }

  /// Pinning is metadata, not content — `updatedAt` stays untouched so the
  /// shelf order beneath the pin row doesn't jump.
  Future<void> setDocumentPinned(Document doc, bool pinned) async {
    doc.pinned = pinned;
    await _isar.writeTxn(() => _isar.documents.put(doc));
  }

  Future<void> moveDocument(Document doc, int? folderId) async {
    doc.folderId = folderId;
    await _isar.writeTxn(() => _isar.documents.put(doc));
  }

  /// Deletes a document with all pages, all ink strokes and its sandbox
  /// files (PDF payload + cover thumbnail). Rows go in ONE transaction;
  /// file cleanup happens after the txn succeeded — a leaked file is better
  /// than a half-deleted document.
  Future<void> deleteDocument(Document doc) async {
    final pages = await _isar.notePages
        .filter()
        .documentIdEqualTo(doc.id)
        .findAll();
    final pageIds = pages.map((p) => p.id).toList(growable: false);

    await _isar.writeTxn(() async {
      if (pageIds.isNotEmpty) {
        await _isar.strokes
            .filter()
            .anyOf(pageIds, (q, int id) => q.pageIdEqualTo(id))
            .deleteAll();
      }
      await _isar.notePages.deleteAllByIds(pageIds);
      await _isar.documents.delete(doc.id);
    });

    for (final relative in [doc.pdfPath, doc.thumbnailPath]) {
      if (relative == null) continue;
      try {
        final file = File(await absolutePathOf(relative));
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best-effort cleanup — never fail the document deletion for it.
      }
    }
  }

  /// Appends a fresh A4 page to a NOTEBOOK (the editor's "+ page").
  /// Returns the new page's 0-based index, or null for PDFs (v1: pages of a
  /// PDF are 1:1 with its source file).
  Future<int?> appendPage(Document doc) async {
    if (doc.type != DocumentType.notebook) return null;
    final indices = await _isar.notePages
        .filter()
        .documentIdEqualTo(doc.id)
        .indexProperty()
        .findAll();
    final next = indices.isEmpty
        ? 0
        : indices.reduce(math.max) + 1;

    final page = NotePage()
      ..documentId = doc.id
      ..index = next
      ..width = 595.28
      ..height = 841.89;

    await _isar.writeTxn(() async {
      await _isar.notePages.put(page);
      doc
        ..pageCount = indices.length + 1
        ..updatedAt = DateTime.now();
      await _isar.documents.put(doc);
    });
    return next;
  }

  /// Bumps `updatedAt` — the editor calls this on close when the session
  /// actually changed ink, so "Date Modified" stays honest without writing
  /// per stroke (the stroke queue already persists ink content itself).
  Future<void> touchDocument(int documentId) async {
    final doc = await _isar.documents.get(documentId);
    if (doc == null) return;
    doc.updatedAt = DateTime.now();
    await _isar.writeTxn(() => _isar.documents.put(doc));
  }
}
