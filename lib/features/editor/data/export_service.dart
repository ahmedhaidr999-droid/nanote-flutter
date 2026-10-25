import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';

import '../../../core/database/collections/document.dart';
import '../../../core/database/collections/note_page.dart';
import '../../../core/database/collections/stroke.dart';
import '../../../core/database/collections/text_block.dart';
import '../../pdf/data/pdf_document_service.dart';
import '../domain/geometry/ink_geometry.dart';
import '../domain/models/stroke_codec.dart';
import '../presentation/canvas/ink_controller.dart';
import '../presentation/canvas/painters/ink_painter.dart';

/// Offline document export (XNota parity) — 100% local, no cloud:
///  • **Export as PDF** — every page rebuilt as a vector PDF page:
///    notebook paper templates, the original PDF content (re-rastered at
///    144 DPI for imported documents), all ink (pen styles honored), text
///    blocks and sticky notes.
///  • **Save page as PNG** — the current page rendered at 2× through the
///    REAL painter stack ([InkPainter.drawInkStroke] — near-pixel-identical
///    to the editor), saved via the system save-file dialog.
///
/// Strokes export as per-segment centerlines whose width follows the exact
/// pen-style pressure profile ([InkOutlineBuilder.effectivePressuresOf]) —
/// the PDF stays vector (ink scales, text stays sharp).
class ExportService {
  ExportService(this._pdf);

  final PdfDocumentService _pdf;

  /// Raster scale for embedded PDF content (2× ≈ 144 DPI).
  static const double _kPdfRasterScale = 2.0;

  /// PNG export render scale.
  static const double _kPngScale = 2.0;

  // ── PDF document export ─────────────────────────────────────────────────

  /// Builds the whole document as a PDF and hands it to the system
  /// save-file dialog. Returns the chosen path, or null when canceled.
  ///
  /// [strokesFor]/[textFor] load one page's content on demand — a
  /// 1000-page PDF only pays for pages that actually have annotations.
  Future<String?> exportDocumentPdf({
    required Document document,
    required List<NotePage> pages,
    required Future<List<Stroke>> Function(NotePage page) strokesFor,
    required Future<List<TextBlock>> Function(NotePage page) textFor,
    void Function(int done, int total)? onProgress,
  }) async {
    final bytes = await buildDocumentPdf(
      document: document,
      pages: pages,
      strokesFor: strokesFor,
      textFor: textFor,
      onProgress: onProgress,
    );
    final safeTitle = _safeFileName(document.title);
    return FilePicker.platform.saveFile(
      fileName: '$safeTitle.pdf',
      bytes: bytes,
    );
  }

  /// Renders [page] as a PNG through the real painter stack and saves it.
  /// Returns the chosen path, or null when canceled.
  Future<String?> exportPagePng({
    required Document document,
    required NotePage page,
    required List<Stroke> strokes,
    required List<TextBlock> textBlocks,
  }) async {
    final image = await renderPageImage(
      document: document,
      page: page,
      strokes: strokes,
      textBlocks: textBlocks,
      scale: _kPngScale,
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    final safeTitle = _safeFileName(document.title);
    return FilePicker.platform.saveFile(
      fileName: '${safeTitle}-p${page.index + 1}.png',
      bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  /// Assembles the document PDF (page size = each page's true point size).
  Future<Uint8List> buildDocumentPdf({
    required Document document,
    required List<NotePage> pages,
    required Future<List<Stroke>> Function(NotePage page) strokesFor,
    required Future<List<TextBlock>> Function(NotePage page) textFor,
    void Function(int done, int total)? onProgress,
  }) async {
    final doc = PdfDocument(compress: true);
    final font = PdfFont.helvetica(doc);

    var done = 0;
    for (final page in pages) {
      final strokes = await strokesFor(page);
      final texts = await textFor(page);

      final pageW = page.width;
      final pageH = page.height;
      final pdfPage = PdfPage(
        doc,
        pageFormat: PdfPageFormat(pageW, pageH),
      );
      final canvas = pdfPage.getGraphics();

      // 1. Background. Notebooks get their paper template; imported PDFs
      //    get a white base (the embedded raster covers the page).
      final template = page.templateOverride ?? document.paperTemplate;
      final shade = page.shadeOverride ?? document.paperShade;
      if (document.pdfPath == null) {
        _pdfDrawPaper(canvas, pageW, pageH, template, shade);
      } else {
        canvas
          ..setFillColor(PdfColor.fromHex('#FFFFFF'))
          ..drawRect(0, 0, pageW, pageH)
          ..fillPath();
      }

      // 2. Original PDF content (imported documents) — re-rastered and
      //    embedded full-bleed (PdfImage.file decodes the PNG bytes in
      //    pure Dart — no platform channels, no network).
      if (document.pdfPath != null) {
        final raster = await _renderPdfPageRaw(
          document.pdfPath!,
          page.pdfPageNumber ?? page.index + 1,
        );
        if (raster != null) {
          final image = PdfImage.file(
            doc,
            bytes: Uint8List.fromList(raster.bytes),
          );
          canvas.drawImage(image, 0, 0, pageW, pageH);
        }
      }

      // 3. Ink — per-segment centerlines following each stroke's exact
      //    pressure profile. PDF origin is BOTTOM-left: every y flips.
      for (final s in strokes) {
        _pdfDrawStroke(canvas, pageH, s);
      }

      // 4. Text blocks + sticky notes.
      for (final b in texts) {
        _pdfDrawTextBlock(canvas, font, pageH, b);
      }

      onProgress?.call(++done, pages.length);
    }

    return await doc.save();
  }

  // ── Page PNG (real painter pipeline) ────────────────────────────────────

  /// Renders one page with the editor's actual renderer at [scale].
  Future<ui.Image> renderPageImage({
    required Document document,
    required NotePage page,
    required List<Stroke> strokes,
    required List<TextBlock> textBlocks,
    double scale = _kPngScale,
  }) async {
    final pageW = page.width;
    final pageH = page.height;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..scale(scale, scale);

    final template = page.templateOverride ?? document.paperTemplate;
    final shade = page.shadeOverride ?? document.paperShade;

    ui.Image? raster;
    if (document.pdfPath != null) {
      raster = await _rasterPdfPage(
        document.pdfPath!,
        page.pdfPageNumber ?? page.index + 1,
        scale: scale,
      );
    }

    if (raster != null) {
      canvas.drawImageRect(
        raster,
        ui.Rect.fromLTWH(
            0, 0, raster.width.toDouble(), raster.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, pageW, pageH),
        ui.Paint()
          ..filterQuality = ui.FilterQuality.medium
          ..isAntiAlias = true,
      );
      raster.dispose();
    } else {
      _uiDrawPaper(canvas, pageW, pageH, template, shade);
    }

    // Ink — the REAL committed-ink renderer (styles included). A throwaway
    // controller hosts the Expando outline cache for the call.
    final tempInk = InkController();
    tempInk.strokes.addAll(strokes);
    for (final s in tempInk.strokes) {
      InkPainter.drawInkStroke(canvas, tempInk, s);
    }
    tempInk.dispose();

    // Text blocks + sticky notes (drawn in page units — canvas pre-scaled).
    for (final b in textBlocks) {
      _uiDrawTextBlock(canvas, b);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (pageW * scale).round(),
      (pageH * scale).round(),
    );
    picture.dispose();
    return image;
  }

  // ── Shared helpers ───────────────────────────────────────────────────────

  /// Raster for the PDF export path — raw render bytes (PNG encoded);
  /// `PdfImage.file` decodes them in pure Dart.
  Future<RenderedPdfPage?> _renderPdfPageRaw(
    String pdfPath,
    int pageNumber, {
    double scale = _kPdfRasterScale,
  }) async {
    try {
      return await _pdf.renderPage(
        relativePath: pdfPath,
        pageNumber: pageNumber,
        scale: scale,
      );
    } catch (_) {
      return null; // a page that fails to raster exports without its bg
    }
  }

  /// Raster for the PNG path — decoded to a ui.Image for the painter stack.
  Future<ui.Image?> _rasterPdfPage(
    String pdfPath,
    int pageNumber, {
    double scale = _kPngScale,
  }) async {
    try {
      final rendered = await _pdf.renderPage(
        relativePath: pdfPath,
        pageNumber: pageNumber,
        scale: scale,
      );
      if (rendered == null) return null;
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(
        Uint8List.fromList(rendered.bytes),
        completer.complete,
      );
      return completer.future;
    } catch (_) {
      return null; // a page that fails to raster exports without its bg
    }
  }

  static String _safeFileName(String title) {
    final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'note' : cleaned;
  }

  /// PdfColor.fromInt reads the same 0xAARRGGBB layout Flutter stores.
  static PdfColor _pdfColorOf(int argb, [double opacity = 1.0]) {
    final c = PdfColor.fromInt(argb);
    return PdfColor(c.red, c.green, c.blue, c.alpha * opacity);
  }

  /// Pure hue (0..1) → [r,g,b] in 0..1 — HSV wheel for the rainbow export.
  static List<double> _hsvToRgb(double h) {
    final i = (h * 6.0).floor() % 6;
    final f = h * 6.0 - (h * 6.0).floor();
    final q = 1.0 - f;
    switch (i) {
      case 0:
        return [1.0, f, 0.0];
      case 1:
        return [q, 1.0, 0.0];
      case 2:
        return [0.0, 1.0, f];
      case 3:
        return [0.0, q, 1.0];
      case 4:
        return [f, 0.0, 1.0];
      case 5:
        return [1.0, 0.0, q];
      default:
        return [1.0, 1.0, 1.0];
    }
  }

  /// Measures a text block in PAGE units (same layout constants as
  /// [TextLayerController.measureOf] / the painter).
  static Size _measureBlock(TextBlock b) {
    final tp = TextPainter(
      text: TextSpan(
        text: b.content.isEmpty ? ' ' : b.content,
        style: TextStyle(
          fontSize: b.fontSize,
          height: 1.28,
          color: Color(b.colorValue),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final size = tp.size;
    tp.dispose();
    return size;
  }

  // ── PDF drawing primitives (bottom-left origin!) ────────────────────────

  void _pdfDrawPaper(
    PdfCanvas canvas,
    double w,
    double h,
    PaperTemplate template,
    PaperShade shade,
  ) {
    final bg = shade == PaperShade.light
        ? PdfColor.fromHex('#FFFFFF')
        : PdfColor.fromHex('#141B24');
    canvas
      ..setFillColor(bg)
      ..drawRect(0, 0, w, h)
      ..fillPath();

    final line =
        PdfColor.fromHex(shade == PaperShade.light ? '#E2E8F0' : '#334155');
    final dot =
        PdfColor.fromHex(shade == PaperShade.light ? '#CBD5E1' : '#475569');

    switch (template) {
      case PaperTemplate.blank:
        break;
      case PaperTemplate.ruled:
        canvas
          ..setStrokeColor(line)
          ..setLineWidth(0.8)
          ..setLineCap(PdfLineCap.round);
        // Page-space lines start 72 pt below the TOP → pdf y = h − 72.
        var y = 0.0;
        final yMax = h - 72.0;
        while (y < yMax) {
          canvas.drawLine(0, y, w, y);
          y += 36;
        }
        break;
      case PaperTemplate.grid:
        canvas
          ..setStrokeColor(line)
          ..setLineWidth(0.6)
          ..setLineCap(PdfLineCap.round);
        var x = 0.0;
        while (x <= w) {
          canvas.drawLine(x, 0, x, h);
          x += 24;
        }
        var y = 0.0;
        while (y <= h) {
          canvas.drawLine(0, y, w, y);
          y += 24;
        }
        break;
      case PaperTemplate.dotted:
        canvas
          ..setStrokeColor(dot)
          ..setLineWidth(1.8)
          ..setLineCap(PdfLineCap.round);
        var y = 12.0;
        while (y < h) {
          var x = 12.0;
          while (x < w) {
            canvas.drawLine(x, y, x + 0.01, y + 0.01);
            x += 24;
          }
          y += 24;
        }
        break;
    }
  }

  void _pdfDrawStroke(PdfCanvas canvas, double pageH, Stroke s) {
    final pts = s.readPoints();
    if (pts.isEmpty) return;

    final isHighlighter = s.tool == InkTool.highlighter;
    final isShape = s.tool == InkTool.shape;
    final style = s.penStyle;

    // Widths follow the exact per-style pressure profile. Style strokes use
    // a low floor so taper/calligraphy extremes survive the export.
    final pressures = (isHighlighter || isShape)
        ? null
        : InkOutlineBuilder.effectivePressuresOf(pts, style);
    final minFactor = (style == PenStyle.taper ||
            style == PenStyle.speed ||
            style == PenStyle.calligraphy)
        ? 0.08
        : InkOutlineBuilder.kMinPressureFactor;

    double widthAt(int i) => isHighlighter || isShape
        ? s.baseWidth
        : math.max(
            0.3,
            s.baseWidth *
                (minFactor + (1 - minFactor) * pressures![i]));

    void segment(int i) {
      canvas.drawLine(
        pts[i].position.dx,
        pageH - pts[i].position.dy,
        pts[i + 1].position.dx,
        pageH - pts[i + 1].position.dy,
      );
    }

    canvas.setLineCap(PdfLineCap.round);
    canvas.setLineJoin(PdfLineJoin.round);

    switch (style) {
      case PenStyle.dashed:
        canvas
          ..setStrokeColor(_pdfColorOf(s.colorValue, s.opacity))
          ..setLineWidth(math.max(0.8, s.baseWidth * 0.8));
        final dash = (s.baseWidth * 3.2).clamp(3.0, 14.0);
        final gap = dash * 0.8;
        var remaining = dash;
        var drawing = true;
        for (var i = 0; i + 1 < pts.length; i++) {
          final a = pts[i].position;
          final b = pts[i + 1].position;
          final len = (b - a).distance;
          if (len < 1e-6) continue;
          var t0 = 0.0;
          var t1 = 0.0;
          while (t0 < len) {
            t1 = math.min(len, t0 + remaining);
            if (drawing) {
              canvas.drawLine(
                a.dx + (b.dx - a.dx) * t0 / len,
                pageH - (a.dy + (b.dy - a.dy) * t0 / len),
                a.dx + (b.dx - a.dx) * t1 / len,
                pageH - (a.dy + (b.dy - a.dy) * t1 / len),
              );
            }
            remaining -= (t1 - t0);
            if (remaining <= 0) {
              drawing = !drawing;
              remaining = drawing ? dash : gap;
            }
            t0 = t1;
          }
        }
        return;

      case PenStyle.rainbow:
        final baseHue = ((s.id % 60) * 6.0) / 360.0;
        for (var i = 0; i + 1 < pts.length; i++) {
          final rgb = _hsvToRgb((baseHue + i * 5.0 / 360.0) % 1.0);
          canvas
            ..setStrokeColor(PdfColor(
                rgb[0], rgb[1], rgb[2], math.max(0.25, s.opacity)))
            ..setLineWidth(widthAt(i).clamp(0.6, 40.0));
          segment(i);
        }
        return;

      case PenStyle.neon:
        // Halo pass, then a bright narrow core — the printable glow.
        for (var i = 0; i + 1 < pts.length; i++) {
          canvas
            ..setStrokeColor(_pdfColorOf(s.colorValue, 0.35 * s.opacity))
            ..setLineWidth(math.max(0.6, widthAt(i) * 1.9));
          segment(i);
        }
        for (var i = 0; i + 1 < pts.length; i++) {
          canvas
            ..setStrokeColor(
                _pdfColorOf(s.colorValue, math.min(1.0, 0.95 * s.opacity)))
            ..setLineWidth(math.max(0.4, widthAt(i) * 0.55));
          segment(i);
        }
        return;

      case PenStyle.pencil:
      case PenStyle.regular:
      case PenStyle.calligraphy:
      case PenStyle.speed:
      case PenStyle.taper:
        if (isHighlighter) {
          canvas
            ..setStrokeColor(_pdfColorOf(s.colorValue, 0.45))
            ..setLineWidth(s.baseWidth);
        } else if (isShape) {
          canvas
            ..setStrokeColor(_pdfColorOf(s.colorValue, s.opacity))
            ..setLineWidth(s.baseWidth);
        } else {
          canvas
            ..setStrokeColor(_pdfColorOf(
                s.colorValue,
                style == PenStyle.pencil
                    ? s.opacity * 0.62
                    : s.opacity));
        }
        for (var i = 0; i + 1 < pts.length; i++) {
          if (!isHighlighter && !isShape) canvas.setLineWidth(widthAt(i));
          segment(i);
        }
        return;
    }
  }

  void _pdfDrawTextBlock(
    PdfCanvas canvas,
    PdfFont font,
    double pageH,
    TextBlock b,
  ) {
    final size = _measureBlock(b);
    final lineAdvance = b.fontSize * 1.28;

    // Sticky background — a rounded, filled swatch in the PDF.
    if (b.stickyColorValue != 0) {
      final rx = b.x - 9;
      final ry = pageH - b.y - size.height - 9;
      final rw = size.width + 18;
      final rh = size.height + 18;
      canvas
        ..setFillColor(_pdfColorOf(b.stickyColorValue))
        ..drawRRect(rx, ry, rw, rh, 6, 6)
        ..fillPath();
    }

    // Fill color also drives drawString's glyphs (pdf 3.10 text painting
    // uses the active fill color — see PdfCanvas.drawString).
    canvas.setFillColor(_pdfColorOf(b.colorValue));
    final lines = b.content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final baselinePage = b.y + b.fontSize * 0.8 + i * lineAdvance;
      if (lines[i].isEmpty) continue;
      canvas.drawString(
        font,
        b.fontSize,
        lines[i],
        b.x,
        pageH - baselinePage,
      );
    }
  }

  // ── ui.Canvas drawing (page units — the canvas is pre-scaled) ──────────

  void _uiDrawPaper(
    ui.Canvas canvas,
    double w,
    double h,
    PaperTemplate template,
    PaperShade shade,
  ) {
    final isDark = shade == PaperShade.dark;
    canvas.drawRect(
      Offset.zero & Size(w, h),
      ui.Paint()
        ..color =
            isDark ? const Color(0xFF141B24) : const Color(0xFFFFFFFF),
    );
    final line = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    final dot = isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1);

    switch (template) {
      case PaperTemplate.blank:
        break;
      case PaperTemplate.ruled:
        final p = ui.Paint()
          ..color = line
          ..strokeWidth = 0.8
          ..style = ui.PaintingStyle.stroke;
        var y = 72.0;
        while (y < h) {
          canvas.drawLine(Offset(0, y), Offset(w, y), p);
          y += 36;
        }
        break;
      case PaperTemplate.grid:
        final p = ui.Paint()
          ..color = line
          ..strokeWidth = 0.6
          ..style = ui.PaintingStyle.stroke;
        var x = 0.0;
        while (x <= w) {
          canvas.drawLine(Offset(x, 0), Offset(x, h), p);
          x += 24;
        }
        var y = 0.0;
        while (y <= h) {
          canvas.drawLine(Offset(0, y), Offset(w, y), p);
          y += 24;
        }
        break;
      case PaperTemplate.dotted:
        final p = ui.Paint()..color = dot;
        var y = 12.0;
        while (y < h) {
          var x = 12.0;
          while (x < w) {
            canvas.drawCircle(Offset(x, y), 0.9, p);
            x += 24;
          }
          y += 24;
        }
        break;
    }
  }

  void _uiDrawTextBlock(ui.Canvas canvas, TextBlock b) {
    final size = _measureBlock(b);

    if (b.stickyColorValue != 0) {
      final bgRect = Rect.fromLTWH(
        b.x - 9,
        b.y - 9,
        size.width + 18,
        size.height + 18,
      );
      final rrect = RRect.fromRectAndRadius(
        bgRect,
        const Radius.circular(6),
      );
      canvas.drawRRect(
        rrect.shift(const Offset(0, 2.5)),
        ui.Paint()
          ..color = const Color(0x26000000)
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4.0),
      );
      canvas.drawRRect(
        rrect,
        ui.Paint()..color = Color(b.stickyColorValue),
      );
    }

    final tp = TextPainter(
      text: TextSpan(
        text: b.content,
        style: TextStyle(
          fontSize: b.fontSize,
          height: 1.28,
          color: Color(b.colorValue),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(b.x, b.y));
    tp.dispose();
  }
}
