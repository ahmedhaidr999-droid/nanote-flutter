import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/utils/path_helpers.dart';

part 'pdf_document_service.g.dart';

/// A rendered page: raw encoded bytes + the geometry needed to compute the
/// raster's effective scale (raster px ÷ PDF points).
class RenderedPdfPage {
  const RenderedPdfPage({
    required this.bytes,
    required this.pageWidthPts,
    required this.pageHeightPts,
    required this.rasterWidthPx,
    required this.rasterHeightPx,
  });

  final List<int> bytes;
  final double pageWidthPts;
  final double pageHeightPts;
  final int rasterWidthPx;
  final int rasterHeightPx;

  double get scale => rasterWidthPx / pageWidthPts;
}

/// Logical PDF page size (points).
class PdfPageSize {
  const PdfPageSize(this.width, this.height);

  final double width;
  final double height;
}

@Riverpod(keepAlive: true)
PdfDocumentService pdfDocumentService(Ref ref) => PdfDocumentService();

/// Owns open [PdfDocument] handles with refcounting.
///
/// Opening a PDF is expensive (native parse) — the editor keeps ONE handle
/// per file, shared by every page view, raster job and size query.
/// `retain`/`release` pair with page-view lifecycles: the document closes
/// the moment its last page view unmounts — no dangling file handles while
/// browsing the library, no re-parse while swiping a 1000-page textbook.
///
/// For every non-lifecycle operation ([pageSize], [renderPage]) the caller
/// is expected to already hold a retain (an open page view or an import in
/// progress); those calls never refcount internally.
class PdfDocumentService {
  final Map<String, _DocHandle> _handles = {};

  /// Keep-alive: returns the open document, opening it on first use.
  Future<PdfDocument> retain(String relativePath) async {
    final existing = _handles[relativePath];
    if (existing != null) {
      existing.refCount++;
      return existing.document;
    }
    final absolute = await absolutePathOf(relativePath);
    final document = await PdfDocument.openFile(absolute);
    _handles[relativePath] = _DocHandle(document)..refCount = 1;
    return document;
  }

  Future<void> release(String relativePath) async {
    final handle = _handles[relativePath];
    if (handle == null) return;
    handle.refCount--;
    if (handle.refCount <= 0) {
      _handles.remove(relativePath);
      await handle.document.close();
    }
  }

  Future<PdfDocument> _open(String relativePath) async {
    final handle = _handles[relativePath];
    if (handle != null) return handle.document;
    // No retain held (page view gone mid-render) — open a transient
    // document and let it close with the render's error path.
    final absolute = await absolutePathOf(relativePath);
    return PdfDocument.openFile(absolute);
  }

  /// Total page count (one fast native call — used by the import flow and
  /// the library metadata without rendering anything).
  Future<int> pageCount(String relativePath) async {
    final doc = await _open(relativePath);
    return doc.pagesCount;
  }

  /// Page size in PDF points (1-based [pageNumber]).
  Future<PdfPageSize> pageSize(String relativePath, int pageNumber) async {
    final doc = await _open(relativePath);
    final page = await doc.getPage(pageNumber);
    try {
      return PdfPageSize(page.width, page.height);
    } finally {
      await page.close();
    }
  }

  /// Renders a full-page raster at [scale] (raster px per PDF point),
  /// clamped so the longest edge never exceeds [maxRasterDimension] —
  /// protects both GPU texture limits and the byte budget in the tile cache.
  ///
  /// Rendering happens on pdfx's native side; the returned bytes are
  /// ready-to-decode PNG.
  Future<RenderedPdfPage?> renderPage({
    required String relativePath,
    required int pageNumber,
    required double scale,
    double maxRasterDimension = 4096,
  }) async {
    final doc = await _open(relativePath);
    final page = await doc.getPage(pageNumber);
    try {
      var w = page.width * scale;
      var h = page.height * scale;
      final longest = w > h ? w : h;
      if (longest > maxRasterDimension) {
        final f = maxRasterDimension / longest;
        w *= f;
        h *= f;
      }
      final image = await page.render(
        width: w.round().clamp(1, 1 << 20),
        height: h.round().clamp(1, 1 << 20),
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      if (image == null) return null;
      return RenderedPdfPage(
        bytes: image.bytes,
        pageWidthPts: page.width,
        pageHeightPts: page.height,
        rasterWidthPx: w.round().clamp(1, 1 << 20),
        rasterHeightPx: h.round().clamp(1, 1 << 20),
      );
    } finally {
      await page.close();
    }
  }
}

class _DocHandle {
  _DocHandle(this.document);

  final PdfDocument document;
  int refCount = 0;
}
