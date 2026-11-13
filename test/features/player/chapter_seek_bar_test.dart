import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/player/media_engine.dart';
import 'package:jellyfin_client/features/player/widgets/chapter_seek_bar.dart';

void main() {
  const chapters = [
    Chapter(Duration.zero, title: 'Opening'),
    Chapter(Duration(minutes: 2), title: 'Part A'),
    Chapter(Duration(minutes: 12), title: 'Part B'),
  ];

  late StreamController<Duration> position;
  late List<Duration> seeks;

  Future<void> pump(WidgetTester tester) async {
    position = StreamController<Duration>.broadcast();
    seeks = [];
    addTearDown(position.close);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 1000,
            child: ChapterSeekBar(
              position: position.stream,
              duration: const Stream.empty(),
              buffer: const Stream.empty(),
              initialDuration: const Duration(minutes: 20),
              chapters: chapters,
              chapterLabel: (i) => chapters[i].title!,
              onSeek: seeks.add,
            ),
          ),
        ),
      ),
    ));
  }

  Offset at(WidgetTester tester, double fraction) {
    final rect = tester.getRect(find.byType(ChapterSeekBar));
    return Offset(rect.left + rect.width * fraction, rect.center.dy);
  }

  testWidgets('hover shows the time and chapter under the pointer', (tester) async {
    await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);

    await mouse.moveTo(at(tester, 0.75)); // 15:00
    await tester.pump();
    expect(find.text('15:00 · Part B'), findsOneWidget);

    await mouse.moveTo(at(tester, 0.05)); // 1:00
    await tester.pump();
    expect(find.text('1:00 · Opening'), findsOneWidget);

    await mouse.moveTo(const Offset(5, 5)); // off the bar
    await tester.pump();
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('click and drag seek', (tester) async {
    await pump(tester);
    await tester.tapAt(at(tester, 0.5));
    await tester.pump();
    expect(seeks, [const Duration(minutes: 10)]);

    final drag = await tester.startGesture(at(tester, 0.2));
    await drag.moveTo(at(tester, 0.4));
    await drag.moveTo(at(tester, 0.6));
    await tester.pump();
    expect(find.text('12:00 · Part B'), findsOneWidget, reason: 'label follows drag');
    await drag.up();
    await tester.pump();
    expect(seeks.last, const Duration(minutes: 12));
  });

  test('timestamps', () {
    expect(formatTimestamp(const Duration(seconds: 65)), '1:05');
    expect(formatTimestamp(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });
}
