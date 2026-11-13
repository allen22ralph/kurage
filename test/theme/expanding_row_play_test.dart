import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/features/home/depth/expanding_row.dart';
import 'package:jellyfin_client/features/home/home_components.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

void main() {
  testWidgets('a closed card keeps its name within what shows', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(FakeServer({})));
    addTearDown(c.dispose);
    await tester.runAsync(() => c.read(sessionControllerProvider.future));
    const name = 'A very long name for an episode that runs on';
    final episode = BaseItem.fromJson(itemJson('e1', name, type: 'Episode'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: ExpandingRow(
            actionLabel: (_) => 'Play',
            data: LibraryRowData(title: 'Episodes', items: AsyncData([episode]), onItemPressed: (_) {}),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    // A closed card is 200 wide, its still 220.
    expect(tester.getSize(find.text(name).first).width, lessThanOrEqualTo(200 - 28));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('an open card: its picture plays, its description opens', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(FakeServer({})));
    addTearDown(c.dispose);
    await tester.runAsync(() => c.read(sessionControllerProvider.future));

    final played = <String>[];
    final opened = <String>[];
    final episode = BaseItem.fromJson(itemJson('e1', 'First', type: 'Episode', extra: {'IndexNumber': 1, 'ParentIndexNumber': 1}));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: ExpandingRow(
            actionLabel: (_) => 'Play',
            onPlay: (e) => played.add(e.id),
            data: LibraryRowData(
              title: 'Episodes',
              items: AsyncData([episode]),
              onItemPressed: (e) => opened.add(e.id),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    // A phone's first tap opens the card.
    await tester.tap(find.text('First').first);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(played, isEmpty);

    // In the middle of the picture.
    final button = find.byIcon(Icons.play_arrow_rounded);
    final picture = tester.getRect(find.text('First').first);
    expect(tester.getCenter(button).dx, lessThan(picture.right + 14));
    await tester.tapAt(tester.getCenter(button));
    await tester.pump();
    expect(played, ['e1']);
    expect(opened, isEmpty);

    await tester.tap(find.text('First').last);
    await tester.pump();
    expect(opened, ['e1']);
    expect(played, ['e1']);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
