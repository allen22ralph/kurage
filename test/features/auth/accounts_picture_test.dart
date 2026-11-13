import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';
import 'package:jellyfin_client/features/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  late FakeServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = FakeServer({
      '/Users/Me': (200, {'Id': 'u1', 'Name': 'sam', 'PrimaryImageTag': 'pic1'}),
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, <Object>[]),
    });
  });

  JellyfinApi api() => JellyfinApi(
        baseUrl: Uri.parse('https://jellyfin.home.arpa'),
        clientInfo: testClientInfo,
        accessToken: 'tok',
        dio: Dio()..httpClientAdapter = server,
      );

  test('a picture is sent base64 encoded to /UserImage (older servers: the old address)', () async {
    server.routes['POST /UserImage'] = (204, null);
    await api().setUserImage('u1', [1, 2, 3], 'image/png');
    final sent = server.requestsTo('/UserImage').single;
    expect(sent.data, base64Encode([1, 2, 3]));
    expect(sent.queryParameters['userId'], 'u1');
    expect(sent.contentType, 'image/png');

    server.routes.remove('POST /UserImage'); // 404: a server before 10.9
    server.routes['POST /Users/u1/Images/Primary'] = (204, null);
    await api().setUserImage('u1', [4], 'image/jpeg');
    expect(server.requestsTo('/Users/u1/Images/Primary'), hasLength(1));
    expect(api().userImageUrl('u1', tag: 't').path, '/UserImage');
  });

  Future<void> pumpApp(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
  }

  testWidgets("Home's title is the server, with its address; a tap opens Account & server", (tester) async {
    await pumpApp(tester);
    expect(find.byTooltip('Connected to sam · jellyfin.home.arpa'), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    expect(find.byTooltip(RegExp('sam \\(signed in\\)')), findsOneWidget);
    await tester.tap(find.byTooltip('Connected to sam · jellyfin.home.arpa'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Check connection'), findsOneWidget, reason: 'Account & server is open');
  });

  testWidgets('Accounts: the signed-in account marked, with Change / Remove picture; centred', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip(RegExp('Accounts')));
    await tester.pumpAndSettle();
    expect(find.text('Signed in'), findsNWidgets(2), reason: 'on the card and on its row');
    expect(find.text('Change picture'), findsOneWidget);
    expect(find.text('Remove picture'), findsOneWidget, reason: 'it has a picture');
    expect(tester.getSize(find.byType(ListView)).width, lessThanOrEqualTo(600));
  });
}
