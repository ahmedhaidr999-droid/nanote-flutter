import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'pdf_document_service.dart';

part 'pdf_tile_cache.g.dart';

@Riverpod(keepAlive: true)
PdfTileCache pdfTileCache(Ref ref) =>
    PdfTileCache(service: ref.watch(pdfDocumentServiceProvider));

/// One decoded, GPU-uploadable page raster.
class PdfRaster {
  const PdfRaster({required this.image, required this.scale});

  final ui.Image image;

  /// Effective raster px per PDF point (≤ the requested bucket — pages can
  /// be clamped by the 4096-px texture cap).
  final double scale;

  /// Decoded RGBA size — the number the byte budget is charged against.
  int get byteLength => image.width * image.height * 4;
}

/// Scale buckets: requests are quantized to this ladder so panning and
/// small zoom jitters never trigger re-rasters. Only crossing a bucket
/// boundary costs a render.
const List<double> kScaleBuckets = [0.35, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0];

/// The virtualization engine for 1000+ page textbooks:
///
///  • PAGE-WINDOWED — only pages a visible [PdfLayer] (± explicit prefetch)
///    ever requests rasters; nothing else is ever rendered or decoded.
///  • SCALE-QUANTIZED — bucket ladder above; renders fire only on bucket
///    transitions, never per frame.
///  • BYTE-BUDGETED LRU — 96 MB default of DECODED pixels (the real cost);
///    eviction disposes `ui.Image`s, so memory is bounded no matter how
///    long the session or how big the deck.
///  • CONCURRENCY-LIMITED — at most [maxConcurrentRenders] native render
///    jobs at once; everything else queues (rapid page-swiping can't spawn
///    a stampede of 20 native renders).
///  • IN-FLIGHT DEDUPE — two layers asking for the same (page, bucket)
///    share one render.
class PdfTileCache extends ChangeNotifier {
  PdfTileCache({
    required this.service,
    this.maxBytes = 96 << 20,
    this.maxConcurrentRenders = 2,
  });

  final PdfDocumentService service;
  final int maxBytes;
  final int maxConcurrentRenders;

  final Map<_RasterKey, _CacheEntry> _entries = {};
  final Set<_RasterKey> _inFlight = {};
  final List<_Job> _queue = [];
  int _activeRenders = 0;
  int _bytes = 0;

  /// Smallest bucket ≥ [targetScale], or the top bucket.
  double bucketFor(double targetScale) {
    for (final b in kScaleBuckets) {
      if (b >= targetScale) return b;
    }
    return kScaleBuckets.last;
  }

  /// Exact bucket hit (also refreshes LRU recency).
  PdfRaster? rasterFor(String docPath, int pageNumber, double bucket) {
    final entry = _entries[_RasterKey(docPath, pageNumber, bucket)];
    if (entry == null) return null;
    entry.lastUse = DateTime.now();
    return entry.raster;
  }

  /// Best raster for a target scale: exact bucket, else the nearest
  /// available bucket for that page (preferring a LOWER bucket — downscale
  /// looks better than a stretched upscale). This is what makes zooming
  /// smooth: the stale raster stays on screen while its sharper
  /// replacement renders.
  PdfRaster? bestRaster(String docPath, int pageNumber, double targetScale) {
    final exactBucket = bucketFor(targetScale);
    final exact = rasterFor(docPath, pageNumber, exactBucket);
    if (exact != null) return exact;

    _CacheEntry? best;
    double bestDist = double.infinity;
    _entries.forEach((key, entry) {
      if (key.docPath != docPath || key.page != pageNumber) return;
      final dist = (key.bucket - targetScale).abs();
      final better = dist < bestDist ||
          (dist == bestDist && key.bucket < (best?.key.bucket ?? 0));
      if (better) {
        bestDist = dist;
        best = entry;
      }
    });
    final found = best;
    if (found == null) return null;
    found.lastUse = DateTime.now();
    return found.raster;
  }

  /// Ensures a raster for (page, bucket-of-targetScale) exists — renders
  /// asynchronously if missing; callers paint via [bestRaster] meanwhile.
  void request(String docPath, int pageNumber, double targetScale) {
    final bucket = bucketFor(targetScale);
    final key = _RasterKey(docPath, pageNumber, bucket);
    if (_entries.containsKey(key) || _inFlight.contains(key)) return;
    _inFlight.add(key);
    _queue.add(_Job(key, targetScale));
    _drain();
  }

  /// Explicit neighbor warm-up (prefetch ±1 pages at the current zoom).
  void prefetch(String docPath, int pageNumber, double targetScale) =>
      request(docPath, pageNumber, targetScale);

  /// Frees every raster of one document — called when its last page view
  /// unmounts, so leaving a textbook immediately returns its memory.
  void clearDoc(String docPath) {
    final doomed = _entries.keys.where((k) => k.docPath == docPath).toList();
    for (final k in doomed) {
      final entry = _entries.remove(k)!;
      _bytes -= entry.raster.byteLength;
      entry.raster.image.dispose();
    }
    if (doomed.isNotEmpty) notifyListeners();
  }

  // ── Render pipeline ─────────────────────────────────────────────────────

  void _drain() {
    while (_activeRenders < maxConcurrentRenders && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      _activeRenders++;
      _runJob(job).whenComplete(() {
        _activeRenders--;
        _drain();
      });
    }
  }

  Future<void> _runJob(_Job job) async {
    try {
      final rendered = await service.renderPage(
        relativePath: job.key.docPath,
        pageNumber: job.key.page,
        scale: job.key.bucket,
      );
      if (rendered == null) return;
      final image = await _decode(rendered.bytes);
      if (!_inFlight.contains(job.key)) {
        image.dispose(); // cancelled mid-flight (doc cleared)
        return;
      }
      _insert(job.key, PdfRaster(image: image, scale: rendered.scale));
      notifyListeners();
    } catch (e) {
      debugPrint('nanote: pdf raster failed (page ${job.key.page}): $e');
    } finally {
      _inFlight.remove(job.key);
    }
  }

  Future<ui.Image> _decode(List<int> bytes) async {
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void _insert(_RasterKey key, PdfRaster raster) {
    _entries[key] = _CacheEntry(key, raster)..lastUse = DateTime.now();
    _bytes += raster.byteLength;
    _evict(protect: key);
  }

  /// LRU eviction down to [maxBytes] of decoded pixels.
  void _evict({required _RasterKey protect}) {
    while (_bytes > maxBytes && _entries.length > 1) {
      _CacheEntry? oldest;
      _entries.forEach((_, entry) {
        if (entry.key == protect) return;
        if (oldest == null || entry.lastUse.isBefore(oldest!.lastUse)) {
          oldest = entry;
        }
      });
      final victim = oldest;
      if (victim == null) break;
      _entries.remove(victim.key);
      _bytes -= victim.raster.byteLength;
      victim.raster.image.dispose();
      notifyListeners();
    }
  }
}

class _RasterKey {
  const _RasterKey(this.docPath, this.page, this.bucket);

  final String docPath;
  final int page;
  final double bucket;

  @override
  bool operator ==(Object other) =>
      other is _RasterKey &&
      other.docPath == docPath &&
      other.page == page &&
      other.bucket == bucket;

  @override
  int get hashCode => Object.hash(docPath, page, bucket);
}

class _CacheEntry {
  _CacheEntry(this.key, this.raster);

  final _RasterKey key;
  final PdfRaster raster;
  late DateTime lastUse;
}

class _Job {
  _Job(this.key, this.targetScale);

  final _RasterKey key;
  final double targetScale;
}
