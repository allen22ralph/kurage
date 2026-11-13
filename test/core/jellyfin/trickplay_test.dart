import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/core/jellyfin/trickplay.dart';
import 'package:jellyfin_client/features/player/widgets/chapter_seek_bar.dart';

BaseItem _item() => BaseItem.fromJson({
      'Id': 'ep1',
      'Name': 'Episode',
      'Type': 'Episode',
      'Trickplay': {
        'src1': {
          '320': {'Width': 320, 'Height': 180, 'TileWidth': 10, 'TileHeight': 10, 'ThumbnailCount': 150, 'Interval': 10000},
          '640': {'Width': 640, 'Height': 360, 'TileWidth': 5, 'TileHeight': 5, 'ThumbnailCount': 150, 'Interval': 10000},
        },
      },
    });

void main() {
  test('picks the resolution nearest 320 and finds the frame for a time', () {
    final t = Trickplay.of(_item(), mediaSourceId: 'src1')!;
    expect((t.width, t.perTile, t.count), (320, 100, 150));
    // 12:35 -> frame 75: first sheet, row 7, column 5.
    expect(t.frameAt(const Duration(minutes: 12, seconds: 35)), (tile: 0, column: 5, row: 7));
    // Past the end: the last frame (149) on the second sheet.
    expect(t.frameAt(const Duration(hours: 2)), (tile: 1, column: 9, row: 4));
    final url = t.tileUrl(Uri.parse('https://jellyfin.home.arpa'), 'ep1', 1, 'tok');
    expect(url.toString(), 'https://jellyfin.home.arpa/Videos/ep1/Trickplay/320/1.jpg?mediaSourceId=src1&api_key=tok');
  });

  group("a server's thumbnail count", () {
    Trickplay of({required int count, int? minutes}) => Trickplay.of(BaseItem.fromJson({
          'Id': 'ep1',
          'Name': 'Episode',
          'Type': 'Episode',
          'RunTimeTicks': ?(minutes == null ? null : minutes * 60 * 10000000),
          'Trickplay': {
            'src1': {
              '320': {'Width': 320, 'Height': 180, 'TileWidth': 10, 'TileHeight': 10, 'ThumbnailCount': count, 'Interval': 10000},
            },
          },
        }))!;

    test('far too low (2 for 24 minutes) still follows the time', () {
      final t = of(count: 2, minutes: 24);
      expect(t.count, 144);
      expect(t.frameAt(const Duration(minutes: 12, seconds: 35)), (tile: 0, column: 5, row: 7));
      expect(t.frameAt(const Duration(minutes: 20)), (tile: 1, column: 0, row: 2));
      // Past the end: the last frame the length needs.
      expect(t.frameAt(const Duration(hours: 2)), (tile: 1, column: 3, row: 4));
    });

    test('that covers the length is kept', () {
      expect(of(count: 150, minutes: 24).count, 150);
    });

    test('with no length known is all there is to go by', () {
      expect(of(count: 2).count, 2);
    });
  });

  test('no trickplay, no preview', () {
    expect(Trickplay.of(BaseItem.fromJson({'Id': 'x', 'Name': 'x', 'Type': 'Movie'})), isNull);
  });

  testWidgets('the seek bar shows the preview above the time while hovering', (tester) async {
    final shown = <Duration>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 1000,
            child: ChapterSeekBar(
              position: const Stream.empty(),
              duration: const Stream.empty(),
              buffer: const Stream.empty(),
              initialDuration: const Duration(minutes: 20),
              chapters: const [],
              chapterLabel: (_) => '',
              onSeek: (_) {},
              preview: (t) {
                shown.add(t);
                return const SizedBox(width: 208, height: 117, key: Key('thumb'));
              },
            ),
          ),
        ),
      ),
    ));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ChapterSeekBar)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('thumb')), findsOneWidget);
    expect(shown.last, const Duration(minutes: 10));
    expect(find.text('10:00'), findsOneWidget);
  });
}
