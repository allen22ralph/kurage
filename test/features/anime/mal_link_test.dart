import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/anime/mal_auth.dart';
import 'package:jellyfin_client/features/anime/mal_account.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

class _Opened implements Exception {}

void main() {
  late List<Uri> opened;

  ProviderContainer container(FakeResponse search) {
    SharedPreferences.setMockInitialValues({'anime.malClientId': 'client-id'});
    FlutterSecureStorage.setMockInitialValues({});
    opened = [];
    final c = ProviderContainer(overrides: [
      ...fakeServerOverrides(FakeServer({'https://api.myanimelist.net/v2/anime': search})),
      // Stops the sign-in once the browser would open (no redirect comes).
      openBrowserProvider.overrideWithValue((url) async {
        opened.add(url);
        throw _Opened();
      }),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test("a client ID MAL doesn't know: said before any browser opens", () async {
    final c = container((400, {'error': 'invalid_request'}));
    await expectLater(
      c.read(malAccountProvider.notifier).link(),
      throwsA(isA<MalAuthException>().having((e) => e.message, 'message', contains("doesn't recognise this client ID"))),
    );
    expect(opened, isEmpty);
  });

  test("MAL unreachable: said, and no browser", () async {
    final c = container(unreachable);
    await expectLater(
      c.read(malAccountProvider.notifier).link(),
      throwsA(isA<MalAuthException>().having((e) => e.message, 'message', startsWith("Couldn't reach MyAnimeList"))),
    );
    expect(opened, isEmpty);
  });

  test('a client ID MAL accepts: on to the browser', () async {
    final c = container((200, {'data': []}));
    await expectLater(c.read(malAccountProvider.notifier).link(), throwsA(isA<_Opened>()));
    expect(opened.single.queryParameters['client_id'], 'client-id');
  });
}
