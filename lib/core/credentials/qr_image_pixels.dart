import 'qr_image_pixels_stub.dart'
    if (dart.library.html) 'qr_image_pixels_web.dart' as platform;

import 'qr_pixels.dart';

/// Decode and downscale an image with the host platform's own image pipeline,
/// or null when there is no such fast path and the caller should fall back to
/// decoding in Dart on a background isolate.
Future<QrPixels?> decodeImageToRgba(List<int> bytes) =>
    platform.decodeImageToRgba(bytes);
