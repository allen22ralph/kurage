import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/week_api.dart';
import 'package:jellyfin_client/features/home/depth/week_timeline.dart';
import 'package:jellyfin_client/features/home/this_week.dart';

WeekSchedule _week({
  bool unreachable = false,
  List<String> problems = const [],
  List<WeekEntry> entries = const [],
  WeekSource source = WeekSource.jellyfin,
  String? note,
}) => WeekSchedule(
  start: weekStart(DateTime.now()),
  entries: entries,
  source: source,
  unreachable: unreachable,
  problems: problems,
  note: note,
);

void main() {
  group('coming back to the app', () {
    test('asks again soon after trouble, otherwise when the list has aged', () {
      final fine = _week(source: WeekSource.arr);
      final troubled = _week(unreachable: true);
      expect(weekNeedsRefresh(fine, const Duration(minutes: 29)), isFalse);
      expect(weekNeedsRefresh(fine, const Duration(minutes: 30)), isTrue);
      expect(weekNeedsRefresh(troubled, const Duration(seconds: 59)), isFalse, reason: 'each change of window on a PC');
      expect(weekNeedsRefresh(troubled, const Duration(minutes: 1)), isTrue);
      expect(weekNeedsRefresh(null, const Duration(minutes: 1)), isTrue, reason: 'never loaded');
    });

    testWidgets('picks up Sonarr being back, without Refresh', (tester) async {
      var asked = 0;
      var now = DateTime(2026, 11, 3, 12);
      late WidgetRef widgetRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            thisWeekProvider.overrideWith((ref) async {
              asked++;
              return _week(unreachable: asked == 1, source: asked == 1 ? WeekSource.jellyfin : WeekSource.arr);
            }),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                widgetRef = ref;
                ref.watch(thisWeekProvider);
                return WeekRefresher(now: () => now, child: const SizedBox());
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(widgetRef.read(thisWeekProvider).value?.troubled, isTrue);

      Future<void> comeBack() async {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
      }

      now = now.add(const Duration(seconds: 10));
      await comeBack();
      expect(asked, 1, reason: 'too soon');

      now = now.add(const Duration(minutes: 2));
      await comeBack();
      expect(asked, 2);
      expect(widgetRef.read(thisWeekProvider).value?.troubled, isFalse);

      now = now.add(const Duration(minutes: 2));
      await comeBack();
      expect(asked, 2, reason: 'all is well, and the list is recent');

      now = now.add(const Duration(minutes: 31));
      await comeBack();
      expect(asked, 3);
    });
  });

  group('the row says so', () {
    final entry = WeekEntry(id: '1', title: 'Frieren', at: DateTime.now());

    Future<void> show(WidgetTester tester, Widget row) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: row))),
        ),
      );
      await tester.pump();
    }

    for (final (name, build) in <(String, Widget Function(WeekRowData))>[
      ('Classic', (d) => WeekRow(data: d)),
      ('Depth', (d) => WeekTimeline(data: d)),
    ]) {
      testWidgets('$name: showing Jellyfin instead', (tester) async {
        await show(
          tester,
          build(WeekRowData(title: 'This week', week: AsyncData(_week(unreachable: true, entries: [entry])))),
        );
        expect(find.text('Sonarr and Radarr unavailable, showing Jellyfin'), findsOneWidget);
        expect(find.text('Frieren'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name: nothing instead either, the row stays and says why', (tester) async {
        await show(
          tester,
          build(
            WeekRowData(
              title: 'This week',
              week: AsyncData(_week(unreachable: true, note: "the server couldn't reach Sonarr or Radarr")),
            ),
          ),
        );
        expect(find.text('This week'), findsOneWidget);
        expect(find.textContaining("couldn't reach"), findsOneWidget);
      });

      testWidgets('$name: no note when all is well', (tester) async {
        await show(
          tester,
          build(WeekRowData(title: 'This week', week: AsyncData(_week(source: WeekSource.arr, entries: [entry])))),
        );
        expect(find.byType(WeekNote), findsNothing);
      });
    }
  });
}
