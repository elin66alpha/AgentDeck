// Run from the repository root: dart run scripts/generate_icons.dart
// assets/icon.png is the transparent master; this only exports platform sizes.
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final master = img.decodePng(File('assets/icon.png').readAsBytesSync())!;
  if (master.numChannels != 4 || master.getPixel(0, 0).a != 0) {
    throw StateError('The master icon must have transparent corners.');
  }
  img.Image resized(int size) => img.copyResize(
        master,
        width: size,
        height: size,
        interpolation: img.Interpolation.average,
      );

  // iOS and maskable Web icons need an opaque background. Navy replaces white;
  // the OS applies its own outer mask. Ordinary desktop/Web icons retain alpha.
  img.Image opaque(img.Image source) {
    final edge = source.getPixel(source.width ~/ 2, source.height ~/ 12);
    final background = img.Image(width: source.width, height: source.height);
    img.fill(
      background,
      color: img.ColorRgb8(edge.r.toInt(), edge.g.toInt(), edge.b.toInt()),
    );
    return img.compositeImage(background, source);
  }

  final targets = <File>[
    ...Directory('android/app/src/main/res')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('ic_launcher.png')),
    ...Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png')),
    ...Directory('macos/Runner/Assets.xcassets/AppIcon.appiconset')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png')),
    ...Directory('web/icons')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png')),
    File('web/favicon.png'),
  ];
  for (final file in targets) {
    final old = img.decodePng(file.readAsBytesSync())!;
    final icon = resized(old.width);
    final path = file.path.replaceAll('\\', '/');
    final needsOpaque = path.startsWith('ios/') || path.contains('maskable');
    file.writeAsBytesSync(img.encodePng(needsOpaque ? opaque(icon) : icon));
    stdout.writeln(
      '${file.path}: ${old.width}px${needsOpaque ? " opaque" : " RGBA"}',
    );
  }
  File('windows/runner/resources/app_icon.ico').writeAsBytesSync(
    img.IcoEncoder().encodeImages([
      for (final size in [16, 24, 32, 48, 64, 128, 256]) resized(size),
    ]),
  );
}
