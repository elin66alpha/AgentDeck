import 'qr_pixels.dart';

/// Native platforms run the pure-Dart decoder on a real background isolate, so
/// there is no platform fast path to take here.
Future<QrPixels?> decodeImageToRgba(List<int> bytes) async => null;
