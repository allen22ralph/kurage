// Renders the app icon (Depth's logo) to the files that can't be vectors:
// Android's icons for versions before 8 (adaptive icons are vectors in
// res/drawable), the Windows .ico, and the Android TV banner.
//
//   flutter test tool/icons
//
// Writes into the project; commit what changes.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _violet = Color(0xFF8F84FF);
const _cyan = Color(0xFF8EE6F5);
const _glow = Color(0xFF1C1F3D);
const _night = Color(0xFF06070B);

/// The logo, from its 32-unit drawing: a violet triangle outline (16,3
/// 29,27 3,27) around a cyan one (16,12 22.5,23.5 9.5,23.5), centred at
/// (16,15) and [scale]d about [centre].
void _logo(Canvas canvas, Offset centre, double scale) {
  Offset p(double x, double y) => centre + Offset((x - 16) * scale, (y - 15) * scale);
  final outer = Path()
    ..moveTo(p(16, 3).dx, p(16, 3).dy)
    ..lineTo(p(29, 27).dx, p(29, 27).dy)
    ..lineTo(p(3, 27).dx, p(3, 27).dy)
    ..close();
  final inner = Path()
    ..moveTo(p(16, 12).dx, p(16, 12).dy)
    ..lineTo(p(22.5, 23.5).dx, p(22.5, 23.5).dy)
    ..lineTo(p(9.5, 23.5).dx, p(9.5, 23.5).dy)
    ..close();
  canvas.drawPath(
    outer,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4 * scale
      ..strokeJoin = StrokeJoin.round
      ..color = _violet
      ..isAntiAlias = true,
  );
  canvas.drawPath(inner, Paint()..color = _cyan..isAntiAlias = true);
}

/// Depth's page: near-black with a violet glow at the top.
void _background(Canvas canvas, Rect rect, {double radius = 0}) {
  final paint = Paint()
    ..shader = ui.Gradient.radial(
      Offset(rect.center.dx, rect.top + rect.height * 0.2),
      rect.longestSide * 0.75,
      const [_glow, _night],
    );
  canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)), paint);
}

Future<Uint8List> _render(int width, int height, void Function(Canvas canvas, Size size) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder), Size(width.toDouble(), height.toDouble()));
  final image = await recorder.endRecording().toImage(width, height);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// A square icon: rounded, with the logo filling about 70%.
Future<Uint8List> _icon(int size) => _render(size, size, (canvas, s) {
      _background(canvas, Offset.zero & s, radius: size * 0.22);
      _logo(canvas, s.center(Offset.zero), size * 0.7 / 26);
    });

/// A .ico holding PNG images (Windows Vista and later read these).
Uint8List _ico(Map<int, Uint8List> pngs) {
  final header = BytesBuilder()
    ..add(_u16(0))
    ..add(_u16(1))
    ..add(_u16(pngs.length));
  var offset = 6 + 16 * pngs.length;
  final data = BytesBuilder();
  for (final MapEntry(key: size, value: png) in pngs.entries) {
    header
      ..addByte(size >= 256 ? 0 : size)
      ..addByte(size >= 256 ? 0 : size)
      ..addByte(0)
      ..addByte(0)
      ..add(_u16(1))
      ..add(_u16(32))
      ..add(_u32(png.length))
      ..add(_u32(offset));
    offset += png.length;
    data.add(png);
  }
  return (header..add(data.takeBytes())).takeBytes();
}

List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

void main() {
  final root = Directory.current.path;
  String at(String path) => '$root/$path';

  testWidgets('render the app icons', (tester) async {
    await tester.runAsync(() async {
      // The banner's name, in a real font (tests draw text as blocks otherwise).
      final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
      final roboto = File('$flutterRoot/bin/cache/artifacts/material_fonts/roboto-bold.ttf');
      final loader = FontLoader('Banner')..addFont(roboto.readAsBytes().then(ByteData.sublistView));
      await loader.load();

      // Android before 8: one PNG per screen density.
      const densities = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
      for (final MapEntry(key: density, value: size) in densities.entries) {
        await File(at('android/app/src/main/res/mipmap-$density/ic_launcher.png')).writeAsBytes(await _icon(size));
      }

      // Windows: the .exe's icon, in the sizes Windows asks for.
      final ico = {for (final s in [16, 24, 32, 48, 64, 128, 256]) s: await _icon(s)};
      await File(at('windows/runner/resources/app_icon.ico')).writeAsBytes(_ico(ico));

      // Android TV: the 320x180dp banner (xhdpi: 640x360 px).
      final banner = await _render(640, 360, (canvas, s) {
        _background(canvas, Offset.zero & s);
        _logo(canvas, Offset(s.height * 0.62, s.height / 2), s.height * 0.52 / 26);
        final name = TextPainter(
          text: const TextSpan(
            text: 'Jellyfin\nClient',
            style: TextStyle(fontFamily: 'Banner', fontSize: 64, height: 1.05, color: Color(0xFFE8E9F0)),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: s.width * 0.6);
        name.paint(canvas, Offset(s.height * 1.08, (s.height - name.height) / 2));
      });
      await Directory(at('android/app/src/main/res/drawable-xhdpi')).create(recursive: true);
      await File(at('android/app/src/main/res/drawable-xhdpi/tv_banner.png')).writeAsBytes(banner);

      // A large copy, for the README and the release pages.
      await File(at('tool/icons/app_icon_512.png')).writeAsBytes(await _icon(512));
    });
  });
}
