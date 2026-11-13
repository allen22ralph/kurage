import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/app/router.dart';
import 'package:jellyfin_client/app/toast.dart';
import 'package:jellyfin_client/core/jellyfin/syncplay.dart';
import 'package:jellyfin_client/features/player/open_player.dart';
import 'package:jellyfin_client/features/syncplay/syncplay_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  late FakeServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/ep1': (200, itemJson('ep1', 'The Journey\'s End', type: 'Episode', extra: {'SeriesName': 'Frieren'})),
    });
  });

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final socket = StreamController<SyncPlayEvent>.broadcast();
    addTearDown(socket.close);
    final c = ProviderContainer(overrides: [
      ...fakeServerOverrides(server),
      syncPlaySocketProvider.overrideWithValue(() async => socket.stream),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    return c;
  }

  void groupPlays(ProviderContainer c, String item) {
    final sync = c.read(syncPlayProvider.notifier);
    sync.handleEvent(const SyncPlayGroupEvent('GroupJoined', 'g1', {'GroupId': 'g1', 'GroupName': 'Movie night', 'Participants': ['ana']}));
    sync.handleEvent(SyncPlayGroupEvent('PlayQueue', 'g1', {
      'Playlist': [
        {'ItemId': item, 'PlaylistItemId': 'p1'},
      ],
      'PlayingItemIndex': 0,
      'StartPositionTicks': 0,
    }));
  }

  String path(ProviderContainer c) => c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

  testWidgets('joining a group that is watching something: asked, not dropped into the player', (tester) async {
    final c = await pumpApp(tester);
    groupPlays(c, 'ep1');
    await tester.pumpAndSettle();
    expect(path(c), isNot(startsWith('/play/')));
    expect(find.textContaining('Movie night is watching Frieren'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);
  });

  testWidgets("the group's episode with dashes in its id is still the one playing: no prompt", (tester) async {
    final c = await pumpApp(tester);
    OpenPlayer.itemId.value = '11d6a6bb2526447bd5d411da1eb01209';
    addTearDown(() => OpenPlayer.itemId.value = null);
    groupPlays(c, '11d6a6bb-2526-447b-d5d4-11da1eb01209');
    await tester.pumpAndSettle();
    expect(find.textContaining('is watching'), findsNothing);
  });

  testWidgets('the same item sent again does not ask (or open) again', (tester) async {
    final c = await pumpApp(tester);
    groupPlays(c, 'ep1');
    await tester.pumpAndSettle();
    final prompt = find.ancestor(of: find.textContaining('is watching'), matching: find.byType(Material)).first;
    await tester.tap(find.descendant(of: prompt, matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();
    expect(find.textContaining('is watching'), findsNothing, reason: 'dismissed');
    groupPlays(c, 'ep1');
    await tester.pumpAndSettle();
    expect(find.textContaining('is watching'), findsNothing);
    expect(path(c), isNot(startsWith('/play/')));
  });

  test('just left an episode: for a moment, nothing but the user reopens it', () {
    OpenPlayer.left('ep1');
    expect(OpenPlayer.justLeft('ep1'), isTrue);
    expect(OpenPlayer.justLeft('ep2'), isFalse);
    expect(OpenPlayer.justLeft('ep1', within: Duration.zero), isFalse);
  });

  testWidgets('Join while that episode already plays: it re-syncs, no second player on top', (tester) async {
    // The player says what it shows (the router can't, for a pushed one).
    OpenPlayer.itemId.value = 'ep1';
    addTearDown(() => OpenPlayer.itemId.value = null);
    final router = GoRouter(initialLocation: '/play/ep1', routes: [
      GoRoute(path: '/', builder: (_, _) => const Text('home')),
      GoRoute(path: '/play/:id', builder: (_, s) => Text('player ${s.pathParameters['id']}')),
    ]);
    addTearDown(router.dispose);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    final sync = c.read(syncPlayProvider.notifier);
    var resyncs = 0;
    sync.resyncRequests.listen((_) => resyncs++);

    openGroupItem(router, sync, 'ep1');
    await tester.pumpAndSettle();
    expect(find.text('player ep1'), findsOneWidget);
    expect(router.canPop(), isFalse, reason: 'nothing opened on top');
    expect(resyncs, 1);

    // Another episode replaces the player rather than stacking.
    openGroupItem(router, sync, 'ep2');
    OpenPlayer.itemId.value = 'ep2';
    await tester.pumpAndSettle();
    expect(find.text('player ep2'), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets('opening the episode closes its "Join in?" prompt', (tester) async {
    final c = await pumpApp(tester);
    // (Not ep1: another test has just "left" it.)
    groupPlays(c, 'ep3');
    await tester.pumpAndSettle();
    expect(find.textContaining('is watching'), findsOneWidget, reason: 'on Home, straight away');
    dismissToast('syncplay-join'); // what the player does on opening
    await tester.pumpAndSettle();
    expect(find.textContaining('is watching'), findsNothing);
  });
}
