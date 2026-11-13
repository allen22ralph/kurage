import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/core/jellyfin/admin_api.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';
import 'package:jellyfin_client/core/time_ago.dart';
import 'package:jellyfin_client/features/library/widgets/action_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  // These hold cards as on a phone or TV, where a hold opens the menu.
  setUp(() => debugHoldOpensMenu = true);
  tearDown(() => debugHoldOpensMenu = null);

  late FakeServer server;

  Map<String, Object?> user(String id, String name, {bool admin = false, Map<String, Object?> policy = const {}}) => {
        'Id': id,
        'Name': name,
        'HasPassword': true,
        'Policy': {'IsAdministrator': admin, 'EnableAllFolders': true, 'AuthenticationProviderId': 'x', ...policy},
      };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = FakeServer({
      '/Users/Me': (200, user('u1', 'sam', admin: true)),
      '/UserViews': (200, pageJson([itemJson('lib1', 'Anime', type: 'CollectionFolder')])),
      '/UserItems/Resume': (200, pageJson([itemJson('m1', 'A Movie')])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, <Object>[]),
      '/System/Info': (200, {
        'ServerName': 'sam',
        'Version': '10.11.11',
        'OperatingSystemDisplayName': 'Linux',
        'SystemArchitecture': 'X64',
      }),
      '/ScheduledTasks': (200, [
        {
          'Id': 't1',
          'Key': 'RefreshLibrary',
          'Name': 'Scan media library',
          'Category': 'Library',
          'State': 'Running',
          'CurrentProgressPercentage': 42.0,
        },
        {
          'Id': 't2',
          'Key': 'CleanCache',
          'Name': 'Clean cache',
          'Category': 'Maintenance',
          'State': 'Idle',
          'LastExecutionResult': {'EndTimeUtc': '2026-10-28T10:00:00Z', 'Status': 'Failed'},
        },
      ]),
      '/Users': (200, [user('u1', 'sam', admin: true), user('u2', 'guest', policy: {'SyncPlayAccess': 'JoinGroups'})]),
      '/Library/MediaFolders': (200, {
        'Items': [
          {'Id': 'lib1', 'Name': 'Anime'},
          {'Id': 'lib2', 'Name': 'Movies'},
        ],
      }),
      '/Localization/ParentalRatings': (200, [
        {'Name': 'PG', 'RatingScore': {'score': 10}},
        {'Name': 'R', 'Value': 17},
      ]),
      '/Devices': (200, {'Items': <Object>[]}),
      'POST /Users/u2/Policy': (204, null),
      'POST /Users/Password': (204, null),
      'POST /Items/m1/Refresh': (204, null),
    });
  });

  JellyfinApi api() => JellyfinApi(
        baseUrl: Uri.parse('https://jellyfin.home.arpa'),
        clientInfo: testClientInfo,
        accessToken: 'tok',
        dio: Dio()..httpClientAdapter = server,
      );

  group('AdminApi', () {
    test('tasks, server info and parental ratings (10.11 RatingScore too) are read', () async {
      final admin = AdminApi(api());
      final tasks = await admin.scheduledTasks();
      expect(tasks.first.running, isTrue);
      expect(tasks.first.progress, 42);
      expect(tasks.last.lastFailed, isTrue);
      expect((await admin.serverInfo()).os, 'Linux · X64');
      expect(ServerInfo.fromJson({'SystemArchitecture': 'X64'}).os, '', reason: '10.11: no OS name');
      expect([for (final r in await admin.parentalRatings()) r.value], [10, 17]);
    });

    test("saving a policy sends the whole policy back (fields the app doesn't show kept)", () async {
      final guest = AdminUser.fromJson(user('u2', 'guest', policy: {'SyncPlayAccess': 'JoinGroups'}));
      expect(guest.policy.syncPlay, SyncPlayAccess.join);
      await AdminApi(api()).savePolicy('u2', guest.policy.copyWith(transcoding: false, maxParentalRating: () => null));
      final sent = server.requestsTo('/Users/u2/Policy').single.data as Map;
      expect(sent['AuthenticationProviderId'], 'x');
      expect(sent['EnableVideoPlaybackTranscoding'], isFalse);
      expect(sent['EnableAudioPlaybackTranscoding'], isFalse);
      expect(sent.containsKey('MaxParentalRating'), isTrue);
      expect(sent['MaxParentalRating'], isNull);
      expect(sent['SyncPlayAccess'], 'JoinGroups');
    });

    test('refresh modes and passwords', () async {
      final admin = AdminApi(api());
      await admin.refreshItem('m1', mode: RefreshMode.replaceAll, replaceImages: true);
      final q = server.requestsTo('/Items/m1/Refresh').single.queryParameters;
      expect(q['metadataRefreshMode'], 'FullRefresh');
      expect(q['replaceAllMetadata'], true);
      expect(q['replaceAllImages'], true);
      await admin.setPassword('u2', '');
      expect(server.requestsTo('/Users/Password').single.data, {'ResetPassword': true});
    });

    test('time ago', () {
      final now = DateTime(2026, 10, 29, 12);
      expect(timeAgo(null), 'never');
      expect(timeAgo(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
      expect(timeAgo(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
      expect(timeAgo(now.subtract(const Duration(days: 1)), now: now), 'yesterday');
    });
  });

  Future<void> pumpApp(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('administrators get Settings > Server: info, scan progress, tasks, users', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Server'));
    await settle(tester);
    expect(find.textContaining('Jellyfin 10.11.11'), findsOneWidget);
    expect(find.text('Scanning… 42 %'), findsOneWidget, reason: 'a scan already running shows its progress');

    await tester.tap(find.text('Users'));
    await settle(tester);
    expect(find.text('sam (you)'), findsOneWidget);
    await tester.tap(find.text('guest'));
    await settle(tester);
    expect(find.text('Join groups only'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Transcoding'));
    await settle(tester);
    expect((server.requestsTo('/Users/u2/Policy').single.data as Map)['EnableVideoPlaybackTranscoding'], isFalse);
    // Leave, so the scan-progress timer stops with the page.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('everyone else: no Server category, no admin entries on cards', (tester) async {
    server.routes['/Users/Me'] = (200, user('u1', 'sam'));
    await pumpApp(tester);
    await tester.longPress(find.text('A Movie'));
    await tester.pumpAndSettle();
    expect(find.text('Mark watched'), findsOneWidget);
    expect(find.text('Refresh metadata…'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Server'), findsNothing);
  });

  testWidgets('administrators: Refresh metadata… on a card', (tester) async {
    await pumpApp(tester);
    await tester.longPress(find.text('A Movie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh metadata…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(server.requestsTo('/Items/m1/Refresh').single.queryParameters['metadataRefreshMode'], 'FullRefresh');
  });
}
