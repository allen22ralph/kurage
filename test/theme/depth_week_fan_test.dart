import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/week_api.dart';
import 'package:jellyfin_client/features/home/depth/week_timeline.dart';
import 'package:jellyfin_client/features/home/this_week.dart';
import 'package:jellyfin_client/features/library/widgets/action_menu.dart';

void main() {
  // These hold cards as on a phone or TV, where a hold opens the menu.
  setUp(() => debugHoldOpensMenu = true);
  tearDown(() => debugHoldOpensMenu = null);

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 21);

  WeekEntry entry(String title, DateTime at) => WeekEntry(id: title, title: title, at: at);

  /// On a day of its own: the first show, and two more.
  WeekSchedule week(DateTime day) => WeekSchedule(
    start: weekStart(now),
    source: WeekSource.arr,
    entries: [entry('Kaiju No. 8', day), entry('Dandadan', day), entry('Frieren', day)],
  );

  Future<void> show(WidgetTester tester, Size size, {DateTime? day}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: WeekTimeline(
                data: WeekRowData(title: 'This week', week: AsyncData(week(day ?? today))),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<TestGesture> hover(WidgetTester tester, Offset at) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(at);
    await tester.pumpAndSettle();
    return mouse;
  }

  group('a day with more than one show', () {
    testWidgets('hovering slides the others out beside it, and leaving takes them back', (tester) async {
      await show(tester, const Size(1600, 900));
      expect(find.text('Dandadan'), findsNothing);
      final first = tester.getRect(find.text('Kaiju No. 8'));

      final mouse = await hover(tester, first.center);
      expect(find.text('Dandadan'), findsOneWidget);
      expect(find.text('Frieren'), findsOneWidget);
      final second = tester.getRect(find.text('Dandadan'));
      final third = tester.getRect(find.text('Frieren'));
      expect(second.top, first.top, reason: 'on the same level');
      expect((second.left - first.left).abs(), greaterThan(150), reason: 'beside it, not over it');
      expect((third.left - first.left).abs(), greaterThan((second.left - first.left).abs()));

      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Dandadan'), findsNothing);
    });

    testWidgets('the gap on the way to a card does not close them', (tester) async {
      await show(tester, const Size(1600, 900));
      final mouse = await hover(tester, tester.getCenter(find.text('Kaiju No. 8')));
      final card = tester.getCenter(find.text('Dandadan'));
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.moveTo(card);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Dandadan'), findsOneWidget);
    });

    testWidgets('a tap on the day still lists them all', (tester) async {
      await show(tester, const Size(1600, 900));
      await tester.tap(find.text('Kaiju No. 8'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('on a phone: holding slides them out in view, and a tap elsewhere closes them', (tester) async {
      await show(tester, const Size(400, 900));
      expect(find.text('Dandadan'), findsNothing);
      await tester.longPress(find.text('Kaiju No. 8'));
      await tester.pumpAndSettle();
      expect(find.text('Dandadan'), findsOneWidget);
      final far = tester.getRect(find.text('Frieren'));
      expect(far.left, greaterThanOrEqualTo(0));
      expect(far.left, lessThan(400), reason: 'scrolled into view');
      expect(find.byType(BottomSheet), findsNothing);

      await tester.tapAt(const Offset(200, 5));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Dandadan'), findsNothing);
    });

    testWidgets('a day with one show does nothing on hover', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: WeekTimeline(
                data: WeekRowData(
                  title: 'This week',
                  week: AsyncData(
                    WeekSchedule(start: weekStart(now), source: WeekSource.arr, entries: [entry('Kaiju No. 8', today)]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await hover(tester, tester.getCenter(find.text('Kaiju No. 8')));
      expect(find.text('Kaiju No. 8'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('which way they go', () {
    test('towards the side with more room, as many as fit, three at most', () {
      expect(weekFanFor(others: 2, left: 0, cardWidth: 180, timelineWidth: 1400), (count: 2, direction: 1));
      expect(weekFanFor(others: 2, left: 1200, cardWidth: 180, timelineWidth: 1400), (count: 2, direction: -1));
      expect(weekFanFor(others: 9, left: 0, cardWidth: 180, timelineWidth: 1400), (count: 3, direction: 1));
      expect(weekFanFor(others: 5, left: 200, cardWidth: 180, timelineWidth: 800), (count: 2, direction: 1));
    });
  });
}
