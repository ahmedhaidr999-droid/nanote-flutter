import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/editor/presentation/canvas/viewport_controller.dart';
import '../data/pdf_tile_cache.dart';

/// The PDF raster layer — a sibling CustomPaint slotted between the paper
/// painter and the ink painter inside the SAME Stack.
///
/// Why alignment is structural, not synchronized: this painter and the ink
/// painter read the SAME [viewport] matrix and draw in the SAME page-space
/// convention (`canvas.transform(matrix.storage)` → page rect at origin).
/// Two layers sharing one transform cannot drift apart at any zoom — there
/// is nothing to "sync". (NotePage.width/height were snapshotted from the
/// PDF's own points at import, so the dst rect IS the ink coordinate
/// system.)
///
/// Compositing note: this must stay a raw CustomPaint sibling — no
/// RepaintBoundary, no Opacity, nothing that creates a compositing layer
/// between the raster and the ink CustomPaint above. Highlighter strokes
/// use BlendMode.multiply; they tint the PDF text because both draw into
/// one shared picture.
class PdfLayer extends ConsumerStatefulWidget {
  const PdfLayer({
    super.key,
    required this.pdfPath,
    required this.pageNumber,
    required this.pageSize,
    required this.viewport,
    this.devicePixelRatio = 1.0,
  });

  /// Stored RELATIVE path (e.g. 'pdfs/<uuid>.pdf').
  final String pdfPath;

  /// 1-based pdfx page number (NotePage.pdfPageNumber).
  final int pageNumber;

  /// Logical page size in points (NotePage.width × height).
  final Size pageSize;

  final ViewportController viewport;
  final double devicePixelRatio;

  @override
  ConsumerState<PdfLayer> createState() => _PdfLayerState();
}

class _PdfLayerState extends ConsumerState<PdfLayer> {
  late final PdfTileCache _cache;
  double _requestedBucket = -1;

  @override
  void initState() {
    super.initState();
    _cache = ref.read(pdfTileCacheProvider);
    widget.viewport.addListener(_onViewportChanged);
  }

  @override
  void dispose() {
    widget.viewport.removeListener(_onViewportChanged);
    super.dispose();
  }

  void _onViewportChanged() => _ensureRaster();

  /// Requests a render ONLY when the zoom crosses a scale-bucket boundary —
  /// panning never re-rasters; small zoom jitter never re-rasters.
  void _ensureRaster() {
    final target =
        widget.viewport.matrix.getMaxScaleOnAxis() * widget.devicePixelRatio;
    final bucket = _cache.bucketFor(target);
    if (bucket != _requestedBucket) {
      _requestedBucket = bucket;
      _cache.request(widget.pdfPath, widget.pageNumber, target);
    }
  }

  @override
  Widget build(BuildContext context) {
    _ensureRaster(); // covers the initial state (no viewport event yet)

    return CustomPaint(
      painter: PdfPainter(
        cache: _cache,
        pdfPath: widget.pdfPath,
        pageNumber: widget.pageNumber,
        pageSize: widget.pageSize,
        viewport: widget.viewport,
        devicePixelRatio: widget.devicePixelRatio,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class PdfPainter extends CustomPainter {
  PdfPainter({
    required this.cache,
    required this.pdfPath,
    required this.pageNumber,
    required this.pageSize,
    required this.viewport,
    required this.devicePixelRatio,
  }) : super(repaint: Listenable.merge([viewport, cache]));

  final PdfTileCache cache;
  final String pdfPath;
  final int pageNumber;
  final Size pageSize;
  final ViewportController viewport;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final target = viewport.matrix.getMaxScaleOnAxis() * devicePixelRatio;
    final raster = cache.bestRaster(pdfPath, pageNumber, target);
    if (raster == null) return; // paper shows through until the raster lands

    canvas.save();
    canvas.transform(viewport.matrix.storage);

    final src = Rect.fromLTWH(
      0,
      0,
      raster.image.width.toDouble(),
      raster.image.height.toDouble(),
    );
    final dst = Offset.zero & pageSize; // page-space rect = ink coordinates

    canvas.drawImageRect(
      raster.image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(PdfPainter old) => true;
  // `repaint:` (viewport ∪ cache) drives repaints; shouldRepaint covers the
  // parent-rebuild case. Raster selection happens per paint via bestRaster,
  // so a just-arrived sharper raster shows up automatically.
}
