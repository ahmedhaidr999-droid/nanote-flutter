import 'package:isar/isar.dart';

import 'document.dart';

part 'note_page.g.dart';

/// One page inside a [Document].
///
/// Pages are their own collection (not embedded in Document):
///  • the editor loads only the visible page window ± prefetch — opening a
///    1000-page medical textbook never materializes all pages in memory;
///  • insert / delete / reorder is a cheap row update, never a document
///    rewrite.
///
/// The composite index `(documentId, index)` makes "pages of doc X in
/// reading order" an index scan.
///
/// Strokes (Step 2) follow the same principle: a separate `Stroke`
/// collection keyed by page id, so pen-up appends a single row and only
/// visible pages ever load their ink.
@collection
class NotePage {
  Id id = Isar.autoIncrement;

  /// Owning document.
  @Index(composite: [CompositeIndex('index')])
  int documentId = 0;

  /// 0-based position within the document.
  int index = 0;

  /// 1-based page number in the source PDF (PDF documents only).
  int? pdfPageNumber;

  /// Page size in logical points (A4 portrait default). Stored per page so
  /// mixed-size slide decks render correctly.
  double width = 595.28;
  double height = 841.89;

  /// Optional per-page paper override (`null` → inherit document defaults).
  ///
  /// Isar 3.1.0+1 cannot persist NULLABLE ENUMS (its generator maps enums to
  /// a non-nullable byte), so the override is stored as an enum ordinal int
  /// and exposed through typed, auto-ignored accessors below.
  int? templateOverrideOrdinal;
  int? shadeOverrideOrdinal;

  /// Typed views over the stored ordinals — auto-ignored by isar_generator
  /// (getters/setters are never persisted), so the domain layer keeps the
  /// original `PaperTemplate?` ergonomics: `page.templateOverride ?? doc.…`.
  @ignore
  PaperTemplate? get templateOverride => templateOverrideOrdinal == null
      ? null
      : PaperTemplate.values[templateOverrideOrdinal!];
  @ignore
  set templateOverride(PaperTemplate? value) =>
      templateOverrideOrdinal = value?.index;
  @ignore
  PaperShade? get shadeOverride => shadeOverrideOrdinal == null
      ? null
      : PaperShade.values[shadeOverrideOrdinal!];
  @ignore
  set shadeOverride(PaperShade? value) => shadeOverrideOrdinal = value?.index;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();

  NotePage({
    this.id = Isar.autoIncrement,
    this.documentId = 0,
    this.index = 0,
    this.pdfPageNumber,
    this.width = 595.28,
    this.height = 841.89,
  });
}
