import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'qr_pixels.dart';

/// Decode and downscale the picked image with the browser instead of the
/// pure-Dart `image` package.
///
/// This is not an optimisation detail: Flutter Web's `compute` has no isolate
/// to run on, so it invokes its callback on the main thread. Decoding a
/// multi-megapixel photo in Dart there freezes the tab outright, and the
/// caller's timeout cannot fire because the timer needs the blocked event
/// loop. The browser decodes off the main thread and scales in a single
/// `drawImage`, leaving Dart only the bounded scan of a small bitmap.
Future<QrPixels?> decodeImageToRgba(List<int> bytes) async {
  final Uint8List data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final web.Blob blob = web.Blob(<JSUint8Array>[data.toJS].toJS);
  final String url = web.URL.createObjectURL(blob);
  try {
    final web.HTMLImageElement image = web.HTMLImageElement();
    image.src = url;
    // decode() resolves once the bitmap is ready and reports a real error for
    // a file that is not an image, unlike waiting on the load event alone.
    await image.decode().toDart;
    final int sourceWidth = image.naturalWidth;
    final int sourceHeight = image.naturalHeight;
    if (sourceWidth <= 0 || sourceHeight <= 0) return null;

    final int longest =
        sourceWidth > sourceHeight ? sourceWidth : sourceHeight;
    final double scale =
        longest > qrScanMaxSide ? qrScanMaxSide / longest : 1.0;
    final int width = (sourceWidth * scale).round().clamp(1, sourceWidth);
    final int height = (sourceHeight * scale).round().clamp(1, sourceHeight);

    final web.HTMLCanvasElement canvas = web.HTMLCanvasElement()
      ..width = width
      ..height = height;
    final web.CanvasRenderingContext2D context =
        canvas.getContext('2d')! as web.CanvasRenderingContext2D;
    context.drawImage(image, 0, 0, width, height);
    final Uint8ClampedList pixels =
        context.getImageData(0, 0, width, height).data.toDart;
    return QrPixels(
      width: width,
      height: height,
      rgba: pixels.buffer.asUint8List(
        pixels.offsetInBytes,
        pixels.lengthInBytes,
      ),
    );
  } finally {
    web.URL.revokeObjectURL(url);
  }
}
