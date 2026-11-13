import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/core/anime/mal_auth.dart';
import 'package:jellyfin_client/core/storage/session_store.dart';
import 'package:jellyfin_client/features/anime/mal_account.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

/// Two Jellyfin users on one server, each with their own settings there.
void main() {
  late FakeServer server;

  /// The server's stored settings for this app, by user.
  late Map<String, Map<String, String>> serverPrefs;

  const path = '/DisplayPreferences/${MalAccountController.preferencesId}';

  String account(String name, {DateTime? expiresAt}) => jsonEncode({
        'username': name,
        'tokens': MalAuth.encode(MalTokens(
          accessToken: 'access-$name',
          refreshToken: 'refresh-$name',
          expiresAt: expiresAt ?? DateTime.now().add(const Duration(days: 30)),
        )),
      });

  Map<String, Object?> session(String userId, String name) => {
        'serverId': 'srv1',
        'serverName': 'sam',
        'baseUrl': 'https://jellyfin.home.arpa',
        'userId': userId,
        'userName': name,
        'accessToken': 'tok-$userId',
      };

  setUp(() {
    serverPrefs = {};
    server = FakeServer({
      'GET $path': (RequestOptions o) => (200, {'CustomPrefs': serverPrefs[o.queryParameters['userId']] ?? {}}),
      'POST $path': (RequestOptions o) {
        final body = o.data is String ? jsonDecode(o.data as String) : o.data;
        serverPrefs[o.queryParameters['userId'] as String] = ((body as Map)['CustomPrefs'] as Map).cast<String, String>();
        return (204, null);
      },
    });
  });

  /// A device with both users signed in, [active] in front.
  Future<ProviderContainer> device({String active = 'u1', Map<String, String> storage = const {}}) async {
    FlutterSecureStorage.setMockInitialValues({
      'sessions': jsonEncode([session('u1', 'sam'), session('u2', 'friend')]),
      'active_session': 'srv1:$active',
      ...storage,
    });
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    return c;
  }

  test("a link from before goes to the user signed in, and onto the server", () async {
    final c = await device(storage: {'mal.account': account('some_mal_user')});
    expect((await c.read(malAccountProvider.future))?.username, 'some_mal_user');
    await pumpEventQueue();
    expect(jsonDecode(serverPrefs['u1']!['account']!)['username'], 'some_mal_user');
    expect(serverPrefs['u2'], isNull, reason: 'not the other user');
  });

  test('linked on one device, there on another', () async {
    serverPrefs['u1'] = {'account': account('some_mal_user')};
    final c = await device();
    expect((await c.read(malAccountProvider.future))?.username, 'some_mal_user');
  });

  test("switching users switches MyAnimeList: each has their own, or none", () async {
    serverPrefs['u1'] = {'account': account('some_mal_user')};
    final c = await device();
    expect((await c.read(malAccountProvider.future))?.username, 'some_mal_user');

    await c.read(sessionControllerProvider.notifier).switchTo(StoredSession.fromJson(session('u2', 'friend')));
    expect(await c.read(malAccountProvider.future), isNull, reason: "the friend hasn't linked one");

    serverPrefs['u2'] = {'account': account('FriendOnMal')};
    c.invalidate(malAccountProvider);
    expect((await c.read(malAccountProvider.future))?.username, 'FriendOnMal');
  });

  test('unlinking is for every device of that user', () async {
    serverPrefs['u1'] = {'account': account('some_mal_user')};
    final phone = await device();
    await phone.read(malAccountProvider.future);
    await phone.read(malAccountProvider.notifier).unlink();
    expect(serverPrefs['u1'], {'account': ''});

    // The PC still had it on the device: the server's "unlinked" wins.
    final pc = await device(storage: {'mal.account.srv1:u1': account('some_mal_user')});
    expect(await pc.read(malAccountProvider.future), isNull);
  });

  test("the server unreachable: the device's copy is used", () async {
    server.routes.clear();
    final c = await device(storage: {'mal.account.srv1:u1': account('some_mal_user')});
    expect((await c.read(malAccountProvider.future))?.username, 'some_mal_user');
  });

  test('an expired token another device has already renewed is taken from the server', () async {
    serverPrefs['u1'] = {'account': account('some_mal_user')};
    final c = await device(
      storage: {'mal.account.srv1:u1': account('some_mal_user', expiresAt: DateTime(2020))},
    );
    // Read while the server is down: the old copy.
    final routes = Map.of(server.routes);
    server.routes.clear();
    await c.read(malAccountProvider.future);
    server.routes.addAll(routes);

    expect(await c.read(malAccountProvider.notifier).accessToken(), 'access-some_mal_user');
    expect(server.requests.where((r) => r.uri.host == 'myanimelist.net'), isEmpty, reason: 'no refresh needed');
  });
}
