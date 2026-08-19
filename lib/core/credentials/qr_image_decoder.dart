import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

import 'qr_pixels.dart';

/// Decode a credential QR from encoded image bytes using the pure-Dart image
/// pipeline. Expensive, so callers run it on a background isolate; platforms
/// with a native decoder should prefer [decodeQrFromRgba] instead.
String decodeCredentialQrImage(Uint8List bytes) {
  final img.Image? image = img.decodeImage(bytes);
  if (image == null) {
    throw const FormatException('Unable to decode image.');
  }
  final img.Image scanImage = _resizeForScanning(image);
  final img.Image rgba = scanImage.convert(numChannels: 4);
  return decodeQrFromRgba(
    rgba.width,
    rgba.height,
    rgba.getBytes(order: img.ChannelOrder.rgba),
  );
}

/// Scan already-decoded, downscaled RGBA pixels for a QR code.
String decodeQrFromRgba(int width, int height, Uint8List rgba) {
  final LuminanceSource source = RGBLuminanceSource(
    width,
    height,
    _argbPixels(width * height, rgba),
  );
  final BinaryBitmap bitmap = BinaryBitmap(HybridBinarizer(source));
  try {
    return QRCodeReader().decode(bitmap).text;
  } catch (_) {
    throw const FormatException('Unable to find a QR code in the image.');
  }
}

/// Pack RGBA bytes into the 0xAARRGGBB words `RGBLuminanceSource` reads its
/// red/green/blue channels out of.
Int32List _argbPixels(int count, Uint8List rgba) {
  final Int32List pixels = Int32List(count);
  for (int i = 0, offset = 0; i < count; i++, offset += 4) {
    pixels[i] =
        (rgba[offset + 3] << 24) |
        (rgba[offset] << 16) |
        (rgba[offset + 1] << 8) |
        rgba[offset + 2];
  }
  return pixels;
}

img.Image _resizeForScanning(img.Image image) {
  final int longestSide =
      image.width > image.height ? image.width : image.height;
  if (longestSide <= qrScanMaxSide) return image;
  final double scale = qrScanMaxSide / longestSide;
  return img.copyResize(
    image,
    width: (image.width * scale).round(),
    height: (image.height * scale).round(),
    interpolation: img.Interpolation.nearest,
  );
}
