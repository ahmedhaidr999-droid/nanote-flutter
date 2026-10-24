import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/database/collections/document.dart';
import '../../../../core/database/collections/note_page.dart';
import '../../../../core/database/isar_provider.dart';
import '../../../../core/utils/path_helpers.dart';
import 'pdf_document_service.dart';

part 'pdf_import_service.g.dart';

@Riverpod(keepAlive: true)
Future<PdfImportService> pdfImportService(Ref ref) async {
  final isar = await ref.watch(isarProvider.future);
  return PdfImportService(
    isar: isar,
    pdfService: ref.watch(pdfDocumentServiceProvider),
  );
}

/// Copies an external PDF into the app-documents sandbox and materializes
/// the full row set in ONE transaction:
///
///     Document(type: pdf, pdfPath, pdfPageCount, thumbnailPath)
///       └─ NotePage × N  (index, pdfPageNumber, per-page size)
///
/// Page sizes: most documents are uniform — import samples the first 3 +
/// last page and reuses the size for all rows (fast path, no matter if the
/// deck has 1000 pages). Only genuinely mixed-size decks fall back to
/// reading every page's size once.
///
/// A 480-px cover thumbnail is rendered to `<docs>/thumbs/` so the library
/// grid (Step 5) never opens the PDF to draw a card.
class PdfImportService {
  PdfImportService({required Isar isar, required PdfDocumentService pdfService})
      : _isar = isar,
        _pdfService = pdfService;

  final Isar _isar;
  final PdfDocumentService _pdfService;

  static const _uuid = Uuid();

  Future<Document> importFromFile({
    String? sourcePath,
    Uint8List? sourceBytes,
    int? folderId,
    String? title,
  }) async {
    assert(
      sourcePath != null || sourceBytes != null,
      'Provide either a source path or source bytes.',
    );

    // 1 ── Copy the payload into the sandbox (uuid name: collision-free,
    //     stored as a RELATIVE path for migration safety).
    final id = _uuid.v4();
    final dir = await pdfsDir();
    final destPath = p.join(dir.path, '$id.pdf');
    if (sourcePath != null) {
      await File(sourcePath).copy(destPath);
    } else {
      await File(destPath).writeAsBytes(sourceBytes!, flush: true);
    }
    final relativePdf = 'pdfs/$id.pdf';

    // 2 ── Open + sample page sizes while holding one retain.
    await _pdfService.retain(relativePdf);
    try {
      final pageCount = await _pdfService.pageCount(relativePdf);

      final first = await _pdfService.pageSize(relativePdf, 1);
      var uniform = true;
      final samplePages = <int>[
        for (var i = 2; i <= math.min(3, pageCount); i++) i,
        if (pageCount > 3) pageCount,
      ];
      for (final n in samplePages) {
        final s = await _pdfService.pageSize(relativePdf, n);
        if ((s.width - first.width).abs() > 0.5 ||
            (s.height - first.height).abs() > 0.5) {
          uniform = false;
          break;
        }
      }

      // Fast path: uniform decks reuse the sampled size for every row.
      // Slow path (rare, genuinely mixed-size decks): read each page once.
      final List<PdfPageSize> sizes;
      if (uniform) {
        sizes = List.filled(pageCount, first);
      } else {
        sizes = <PdfPageSize>[];
        for (var i = 0; i < pageCount; i++) {
          sizes.add(await _pdfService.pageSize(relativePdf, i + 1));
        }
      }

      // 3 ── Cover thumbnail (480 px wide).
      final thumbRendered = await _pdfService.renderPage(
        relativePath: relativePdf,
        pageNumber: 1,
        scale: 480 / first.width,
      );
      String? relativeThumb;
      if (thumbRendered != null) {
        final tDir = await thumbsDir();
        final thumbFile = File(p.join(tDir.path, '$id.png'));
        await thumbFile.writeAsBytes(
          Uint8List.fromList(thumbRendered.bytes),
          flush: true,
        );
        relativeThumb = 'thumbs/$id.png';
      }

      // 4 ── One transaction: document + all page rows.
      final doc = Document()
        ..title = title ??
            p.basenameWithoutExtension(
              sourcePath ?? 'Untitled PDF',
            )
        ..folderId = folderId
        ..type = DocumentType.pdf
        ..pdfPath = relativePdf
        ..pdfPageCount = pageCount
        ..pageCount = pageCount
        ..thumbnailPath = relativeThumb
        ..createdAt = DateTime.now()
        ..updatedAt = DateTime.now();

      final pages = List.generate(pageCount, (i) {
        final size = sizes[i];
        return NotePage()
          ..documentId = -1 // assigned inside the txn below
          ..index = i
          ..pdfPageNumber = i + 1
          ..width = size.width
          ..height = size.height;
      });

      await _isar.writeTxn(() async {
        final docId = await _isar.documents.put(doc);
        for (final page in pages) {
          page.documentId = docId;
        }
        await _isar.notePages.putAll(pages);
      });

      return doc;
    } finally {
      await _pdfService.release(relativePdf);
    }
  }
}
