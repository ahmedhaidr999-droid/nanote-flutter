import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/collections/document.dart';
import '../../../../core/database/collections/note_page.dart';
import '../../../../core/database/collections/stroke.dart';
import '../../../pdf/data/pdf_tile_cache.dart';
import '../../data/stroke_repository.dart';
import '../../domain/models/stroke_codec.dart';

/// The Notewise-style page-thumbnail rail: a left slide-in panel with one
/// mini preview per page. Tap to jump (and close).
///
/// Previews are VIRTUALIZED like everything else in Nanote:
///  • PDF pages ask the shared [PdfTileCache] for the smallest raster bucket
///    (0.35× — thumbnail sized) — never a fresh render;
///  • NOTEBOOK pages lazily load that page's strokes from the repository
///    the first time their tile scrolls into view.
class PageThumbnailsPanel extends ConsumerStatefulWidget {
  const PageThumbnailsPanel({
    super.key,
    required this.document,
    required this.pages,
    required this.currentIndex,
    required this.onSelect,
  });

  final Document document;
  final List<NotePage> pages;
  final int currentIndex;
  final void Function(int index) onSelect;

  @override
  ConsumerState<PageThumbnailsPanel> createState() =>
      _PageThumbnailsPanelState();
}

class _PageThumbnailsPanelState extends ConsumerState<PageThumbnailsPanel> {
  final Map<int, List<Stroke>> _strokes = {};
  final Set<int> _loading = {};
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Land with the CURRENT page visible — jumping to long documents must
    // not start the rail at page 1.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final est = _scroll.position.maxScrollExtent *
          (widget.currentIndex / widget.pages.length);
      _scroll.jumpTo(est.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _ensureStrokes(NotePage page) {
    if (_strokes.containsKey(page.id) || _loading.contains(page.id)) return;
    _loading.add(page.id);
    ref.read(strokeRepositoryProvider.future).then((repo) {
      return repo.loadStrokes(page.id);
    }).then((loaded) {
      if (!mounted) return;
      setState(() {
        _strokes[page.id] = loaded;
        _loading.remove(page.id);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 168,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(4, 0)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Text(
              'Pages',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              itemCount: widget.pages.length,
              itemBuilder: (context, i) {
                final page = widget.pages[i];
                if (widget.document.pdfPath == null) _ensureStrokes(page);
                final isCurrent = i == widget.currentIndex;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: InkWell(
                    onTap: () => widget.onSelect(i),
                    borderRadius: BorderRadius.circular(10),
                    child: Column(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isCurrent
                                  ? const Color(0xFF155EEF)
                                  : scheme.outlineVariant,
                              width: isCurrent ? 2.5 : 1,
                            ),
                            boxShadow: isCurrent
                                ? const [
                                    BoxShadow(
                                      color: Color(0x33155EEF),
                                      blurRadius: 8,
                                    ),
                                  ]
                                : null,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6.5),
                            child: AspectRatio(
                              aspectRatio: page.width / page.height,
                              child: _PagePreview(
                                document: widget.document,
                                page: page,
                                strokes: _strokes[page.id],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${i + 1}',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: isCurrent
                                    ? const Color(0xFF155EEF)
                                    : scheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One page preview: PDF raster via the tile cache, or paper + strokes.
class _PagePreview extends ConsumerWidget {
  const _PagePreview({
    required this.document,
    required this.page,
    this.strokes,
  });

  final Document document;
  final NotePage page;
  final List<Stroke>? strokes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pdfPath = document.pdfPath;
    if (pdfPath != null) {
      final cache = ref.read(pdfTileCacheProvider);
      final pageNumber = page.pdfPageNumber ?? (page.index + 1);
      // Thumbnail bucket — the smallest raster the cache can serve.
      cache.request(pdfPath, pageNumber, 0.35);
      return AnimatedBuilder(
        animation: cache,
        builder: (context, _) {
          final raster = cache.bestRaster(pdfPath, pageNumber, 0.35);
          return CustomPaint(
            painter: _MiniPagePainter(
              pageSize: Size(page.width, page.height),
              raster: raster?.image,
              template: page.templateOverride ?? document.paperTemplate,
              shade: page.shadeOverride ?? document.paperShade,
              strokes: const [],
            ),
            size: Size.infinite,
          );
        },
      );
    }
    return CustomPaint(
      painter: _MiniPagePainter(
        pageSize: Size(page.width, page.height),
        raster: null,
        template: page.templateOverride ?? document.paperTemplate,
        shade: page.shadeOverride ?? document.paperShade,
        strokes: strokes ?? const [],
      ),
      size: Size.infinite,
    );
  }
}

/// Lightweight mini renderer — deliberately NOT the engine painters:
/// thumbnails draw simple stroked polylines (no variable-width outlines,
/// no tessellation caches) at a fraction of the cost.
class _MiniPagePainter extends CustomPainter {
  const _MiniPagePainter({
    required this.pageSize,
    required this.raster,
    required this.template,
    required this.shade,
    required this.strokes,
  });

  final Size pageSize;
  final ui.Image? raster;
  final PaperTemplate template;
  final PaperShade shade;
  final List<Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / pageSize.width;
    final isDark = shade == PaperShade.dark;

    // Paper.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = isDark ? const Color(0xFF16181D) : Colors.white,
    );

    // PDF raster.
    final img = raster;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(
            0, 0, img.width.toDouble(), img.height.toDouble()),
        Offset.zero & size,
        Paint()
          ..filterQuality = FilterQuality.low
          ..isAntiAlias = true,
      );
    } else {
      // Paper template (notebooks) — a few lines carry the identity.
      final line = Paint()
        ..color = isDark
            ? const Color(0x2EFFFFFF)
            : const Color(0x1F655585)
        ..strokeWidth = 0.5;
      if (template != PaperTemplate.blank) {
        const spacing = 32.0;
        for (var y = spacing; y < pageSize.height; y += spacing) {
          if (template == PaperTemplate.dotted) {
            for (var x = spacing / 2; x < pageSize.width; x += spacing) {
              canvas.drawCircle(Offset(x, y) * s, 0.8, line);
            }
          } else {
            canvas.drawLine(Offset(0, y) * s, Offset(pageSize.width, y) * s,
                line);
            if (template == PaperTemplate.grid) {
              for (var x = spacing; x < pageSize.width; x += spacing) {
                canvas.drawLine(Offset(x, 0) * s, Offset(x, pageSize.height) * s,
                    line);
              }
            }
          }
        }
      }
    }

    // Strokes — simple polylines (thumbnail fidelity is deliberately lower
    // than the editor: no outlines, no glow, just readable marks).
    for (final st in strokes) {
      final pts = st.readPoints();
      if (pts.isEmpty) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      if (st.tool == InkTool.highlighter) {
        paint.color = Color(st.colorValue).withAlpha(115);
      } else if (st.tool == InkTool.shape) {
        paint.color = Color(st.colorValue);
      } else {
        switch (st.penStyle) {
          case PenStyle.rainbow:
            var hue = ((st.id % 60) * 6.0) % 360.0;
            for (var i = 0; i + 1 < pts.length; i++) {
              paint
                ..color = HSVColor.fromAHSV(1, hue % 360, 0.85, 1.0)
                    .toColor()
                ..strokeWidth =
                    (st.baseWidth * s).clamp(0.4, 3.0);
              canvas.drawLine(pts[i].position * s, pts[i + 1].position * s,
                  paint);
              hue += 6.0;
            }
            continue;
          case PenStyle.pencil:
            paint.color = Color(st.colorValue).withOpacity(0.6 * st.opacity);
          case PenStyle.neon:
            paint.color = Color(st.colorValue);
          case PenStyle.regular:
          case PenStyle.calligraphy:
          case PenStyle.dashed:
          case PenStyle.speed:
          case PenStyle.taper:
            paint.color = st.opacity < 0.999
                ? Color(st.colorValue).withOpacity(st.opacity)
                : Color(st.colorValue);
        }
      }
      paint.strokeWidth = (st.baseWidth * s).clamp(0.4, 3.0);
      final path = Path()
        ..moveTo(pts.first.position.dx * s, pts.first.position.dy * s);
      for (final p in pts.skip(1)) {
        path.lineTo(p.position.dx * s, p.position.dy * s);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_MiniPagePainter old) =>
      old.raster != raster || old.strokes != strokes;
}
