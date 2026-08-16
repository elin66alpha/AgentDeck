import 'dart:typed_data';

/// Longest side a credential QR image is downscaled to before scanning. Large
/// enough to keep a phone photo of a printed code readable, small enough that
/// the scan itself stays fast.
const int qrScanMaxSide = 768;

/// Decoded, already downscaled image pixels in RGBA byte order.
class QrPixels {
  const QrPixels({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}
