import 'package:isar/isar.dart';

part 'document.g.dart';

/// A Nanote document — either a blank notebook or an imported PDF.
///
/// Performance contract ("the instant home screen"):
///  • Everything the grid/list view needs lives directly on this
///    collection. The library screen NEVER joins into pages or strokes.
///  • Thumbnails are pre-rendered PNG/WebP files on disk; only the relative
///    path is stored here. Thousands of documents → thousands of cheap path
///    strings, loaded through the OS image cache.
///  • The composite index `(folderId, updatedAt)` turns the default
///    "open folder → sort by Date Modified" query into a pure index scan.
@collection
class Document {
  Id id = Isar.autoIncrement;

  /// Document title. Value-indexed for prefix search.
  @Index(type: IndexType.value)
  String title = 'Untitled';

  /// Containing folder. `null` → library root shelf.
  ///
  /// Composite index `(folderId, updatedAt)`: the default library query —
  /// "documents in this folder, newest-modified first" — never touches the
  /// table heap, only the index.
  @Index(composite: [CompositeIndex('updatedAt')])
  int? folderId;

  /// Notebook or imported PDF. (Ordinal storage — append new values ONLY
  /// at the end of the enum; never reorder.)
  @enumerated
  DocumentType type = DocumentType.notebook;

  // ── PDF source (only when type == DocumentType.pdf) ──────────────────────
  /// Path RELATIVE to the app-documents root. Never absolute — survives
  /// device migration, OS backup/restore, and app updates.
  String? pdfPath;
  int pdfPageCount = 0;

  // ── Paper defaults (notebooks; individual pages may override) ────────────
  @enumerated
  PaperTemplate paperTemplate = PaperTemplate.ruled;
  @enumerated
  PaperShade paperShade = PaperShade.light;

  /// Relative path to the pre-rendered cover thumbnail (grid view).
  String? thumbnailPath;

  int pageCount = 0;

  /// Pinned documents float to the top of their folder regardless of sort.
  bool pinned = false;

  /// Manual ordering position within the folder (used when sort == manual).
  int sortIndex = 0;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();

  Document({
    this.id = Isar.autoIncrement,
    this.title = 'Untitled',
    this.folderId,
    this.type = DocumentType.notebook,
    this.pdfPath,
    this.pdfPageCount = 0,
    this.paperTemplate = PaperTemplate.ruled,
    this.paperShade = PaperShade.light,
    this.thumbnailPath,
    this.pageCount = 0,
    this.pinned = false,
    this.sortIndex = 0,
  });
}

enum DocumentType { notebook, pdf }

/// Blank-paper backgrounds. Rendered PROCEDURALLY by painters (Steps 2 & 5),
/// never as raster assets — crisp at 500% zoom, themeable light/dark.
enum PaperTemplate { ruled, grid, dotted, blank }

/// Light/dark paper variant. Deliberately independent of system dark mode —
/// the user picks per document (Notewise behaviour: dark ink on dark paper
/// is a readability hazard the app refuses to create automatically).
enum PaperShade { light, dark }
