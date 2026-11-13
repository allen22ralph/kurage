import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/week_api.dart';
import 'package:jellyfin_client/features/home/depth/week_timeline.dart';
import 'package:jellyfin_client/features/home/this_week.dart';

void main() {
  group('how open a card is', () {
    double fold(double entered, {int day = 0}) => weekCardFold(entered: entered, height: 130, viewport: 900, day: day);

    test('shut until part of it is in view, open by the middle of the screen', () {
      expect(fold(0), 0);
      expect(fold(65), 0, reason: 'half of it in view: only now starting');
      expect(fold(300), inExclusiveRange(0, 1), reason: 'part-way');
      expect(fold(0.44 * 1030), 1);
      expect(fold(2000), 1);
    });

    test('each day opens after the one before', () {
      expect(fold(300, day: 2), lessThan(fold(300)));
      expect(fold(300, day: 6), lessThan(fold(300, day: 2)));
      expect(fold(2000, day: 6), 1);
    });

    test('the line draws with the scroll', () {
      expect(weekLineDrawn(entered: 0, viewport: 900), 0);
      expect(weekLineDrawn(entered: 180, viewport: 900), closeTo(0.5, 0.001));
      expect(weekLineDrawn(entered: 400, viewport: 900), 1);
    });
  });

  group('on the page', () {
    final now = DateTime.now();
    final monday = weekStart(now);

    Future<ScrollController> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    const SizedBox(height: 1000),
                    WeekTimeline(
                      data: WeekRowData(
                        title: 'This week',
                        week: AsyncData(
                          WeekSchedule(
                            start: monday,
                            source: WeekSource.arr,
                            entries: [WeekEntry(id: 'k', title: 'Kaiju No. 8', at: DateTime(monday.year, monday.month, monday.day, 21))],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return scroll;
    }

    double opacityOfCard(WidgetTester tester) {
      final card = find.ancestor(of: find.text('Kaiju No. 8'), matching: find.byType(Opacity));
      // (The card's own is the outermost.)
      return tester.widget<Opacity>(card.last).opacity;
    }

    testWidgets('a PC: follows the scroll, holds part-way, and folds back', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final scroll = await show(tester);
      expect(opacityOfCard(tester), 0, reason: 'below the screen');

      Future<void> to(double y) async {
        scroll.jumpTo(y);
        await tester.pump();
      }

      await to(500);
      final partWay = opacityOfCard(tester);
      expect(partWay, inExclusiveRange(0, 1));
      await tester.pump(const Duration(seconds: 5));
      expect(opacityOfCard(tester), partWay, reason: 'stays there: no timer finishing it');

      await to(800);
      expect(opacityOfCard(tester), 1);
      await to(0);
      expect(opacityOfCard(tester), 0, reason: 'folded back up');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Android: plays once by itself, and stays open', (tester) async {
      final scroll = await show(tester);
      scroll.jumpTo(800);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(opacityOfCard(tester), 1);
      scroll.jumpTo(0);
      await tester.pump(const Duration(seconds: 1));
      expect(opacityOfCard(tester), 1, reason: 'unchanged');
    });
  });
}
