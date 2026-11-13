import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/features/downloads/downloads.dart';
import 'package:jellyfin_client/features/downloads/downloads_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

Map<String, Object?> _episode(String id, int season, int number) => itemJson(id, 'Episode $number', type: 'Episode', extra: {
      'SeriesId': 'apo',
      'SeriesName': 'The Apothecary Diaries',
      'SeasonId': 'apo-s$season',
      'SeasonName': 'Season $season',
      'ParentIndexNumber': season,
      'IndexNumber': number,
    });

void main() {
  late Directory dir;
  late ProviderContainer c;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('downloads-screen');
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    // Five finished downloads over two seasons, as left by an earlier run.
    final eps = [_episode('a1', 1, 1), _episode('a2', 1, 2), _episode('b1', 2, 1), _episode('b2', 2, 2), _episode('b3', 2, 3)];
    for (final e in eps) {
      File('${dir.path}${Platform.pathSeparator}${e['Id']}.mkv').writeAsStringSync('x' * 100);
    }
    File('${dir.path}${Platform.pathSeparator}index.json').writeAsStringSync(jsonEncode({
      'records': [
        for (final e in eps)
          {'itemId': e['Id'], 'item': e, 'fileName': '${e['Id']}.mkv', 'status': 'done', 'received': 100, 'total': 100},
      ],
    }));
    c = ProviderContainer(overrides: [
      ...fakeServerOverrides(FakeServer({})),
      downloadsDirProvider.overrideWith((ref) async => dir),
    ]);
    await c.read(sessionControllerProvider.future);
  });

  tearDown(() async {
    c.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Real file reads: outside the test's fake clock.
    await tester.runAsync(() => c.read(downloadsProvider.future));
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: DownloadsScreen())));
    await tester.pumpAndSettle();
  }

  Finder row(String name) => find.ancestor(of: find.text(name), matching: find.byType(ListTile)).first;

  testWidgets('grouped by show and season, each with its count and size', (tester) async {
    await pumpScreen(tester);
    expect(find.text('The Apothecary Diaries · Season 1'), findsOneWidget);
    expect(find.text('The Apothecary Diaries · Season 2'), findsOneWidget);
    expect(find.text('3 episodes · 0 KB'), findsOneWidget);
    // Collapsing a season hides its episodes.
    await tester.tap(find.text('The Apothecary Diaries · Season 2'));
    await tester.pumpAndSettle();
    expect(find.text('Episode 3'), findsNothing);
  });

  testWidgets('long press, tap, Shift+click: select several, then delete them together', (tester) async {
    await pumpScreen(tester);
    await tester.longPress(row('Episode 1'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected · 0 KB'), findsOneWidget);
    // While selecting, a tap picks rather than plays.
    await tester.tap(row('Episode 2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 selected'), findsOneWidget);

    // Shift+click: everything from the last picked to here (into season 2).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.descendant(of: find.byType(ListView), matching: find.text('Episode 3')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.textContaining('5 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 5 downloads?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    // Deleting files: real I/O, a step at a time.
    for (var i = 0; i < 100 && c.read(downloadsProvider).value!.records.isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    bool filesLeft() => dir.listSync().whereType<File>().any((f) => f.path.endsWith('.mkv'));
    for (var i = 0; i < 100 && filesLeft(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(c.read(downloadsProvider).value!.records, isEmpty);
    expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.mkv')), isEmpty);
  });

  testWidgets("a season's checkbox selects all of it; Esc stops selecting", (tester) async {
    await pumpScreen(tester);
    final header = find.ancestor(of: find.text('The Apothecary Diaries · Season 2'), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: header, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 selected'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
  });
}
