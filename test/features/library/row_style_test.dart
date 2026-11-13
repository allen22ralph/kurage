import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/features/library/widgets/card_actions.dart';
import 'package:jellyfin_client/features/library/widgets/media_card.dart';
import 'package:jellyfin_client/features/library/widgets/media_row.dart';
import 'package:jellyfin_client/features/library/widgets/side_scroll.dart';
import 'package:jellyfin_client/features/settings/appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  final items = [
    for (var i = 0; i < 20; i++)
      BaseItem.fromJson(itemJson('m$i', 'Movie $i', extra: {
        'RunTimeTicks': 24 * 600000000,
        'UserData': {'Played': false, 'PlaybackPositionTicks': 6 * 600000000, 'PlayedPercentage': 25.0},
      })),
  ];

  Future<ProviderContainer> pump(WidgetTester tester, RowStyle style) async {
    SharedPreferences.setMockInitialValues({'appearance.rowStyle': style.name});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [...fakeServerOverrides(FakeServer({})), isTvProvider.overrideWithValue(false)]);
    addTearDown(c.dispose);
    await c.read(appearanceProvider.future);
    await c.read(sessionControllerProvider.future);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: MediaRow(
            title: 'Continue watching',
            items: AsyncData(items),
            onItemPressed: (_) {},
            cardRow: CardRow.continueWatching,
            shape: CardShape.landscape,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('Paged: ‹ › by the title move the row a page; time left on Continue watching', (tester) async {
    await pump(tester, RowStyle.paged);
    expect(find.byTooltip('More'), findsOneWidget);
    final back = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_left));
    expect(back.onPressed, isNull, reason: 'at the start: nothing back');
    final list = tester.widget<ListView>(find.byType(ListView));
    final controller = list.controller!;
    expect(controller.offset, 0);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(800), reason: 'about a page on');
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_left)).onPressed, isNotNull);
    expect(find.text('18m left'), findsWidgets);
  });

  testWidgets('Classic: rows as before (no pager, no time left)', (tester) async {
    await pump(tester, RowStyle.classic);
    expect(find.byType(RowPager), findsOneWidget);
    expect(find.byTooltip('More'), findsNothing);
    expect(find.text('18m left'), findsNothing);
    expect(find.byType(MediaCard), findsWidgets);
  });
}
