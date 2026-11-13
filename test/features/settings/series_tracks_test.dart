import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/features/settings/series_tracks.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  test('a show\'s language goes first, without duplicates', () {
    expect(SeriesTrackChoice.prefer('eng', 'jpn,ja'), 'eng,jpn,ja');
    expect(SeriesTrackChoice.prefer('jpn', 'jpn,ja'), 'jpn,ja');
    expect(SeriesTrackChoice.prefer(null, 'jpn,ja'), 'jpn,ja');
  });

  test('choices are stored per show and survive restarts', () async {
    SharedPreferences.setMockInitialValues({});
    var c = ProviderContainer();
    await c.read(seriesTracksProvider.notifier).setAudio('rz', 'eng');
    await c.read(seriesTracksProvider.notifier).setSubtitle('rz', null, off: true);
    await c.read(seriesTracksProvider.notifier).setSubtitle('fr', 'spa');
    c.dispose();

    c = ProviderContainer();
    addTearDown(c.dispose);
    final choices = await c.read(seriesTracksProvider.future);
    expect((choices['rz']!.audio, choices['rz']!.subtitlesOff), ('eng', true));
    expect((choices['fr']!.subtitle, choices['fr']!.subtitlesOff), ('spa', false));
  });

  test("the account's choices: the same tracks on every device signed in as the user", () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    // Picked on another device: Japanese audio, English subtitles.
    final server = FakeServer({
      '/DisplayPreferences/${SeriesTracksController.preferencesId}': (200, {
        'CustomPrefs': {
          'rz': jsonEncode({'audio': 'jpn', 'subtitle': 'eng', 'subtitlesOff': false}),
          // Not a choice (the server's own, or another app's): skipped, the rest kept.
          'chromecastVersion': 'stable',
        },
      }),
      'POST /DisplayPreferences/${SeriesTracksController.preferencesId}': (204, null),
    });
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await c.read(sessionControllerProvider.future);
    final choices = await c.read(seriesTracksProvider.future);
    expect((choices['rz']!.audio, choices['rz']!.subtitle), ('jpn', 'eng'));

    // A change here goes to the account too.
    await c.read(seriesTracksProvider.notifier).setSubtitle('rz', null, off: true);
    final sent = server.requestsTo('/DisplayPreferences/${SeriesTracksController.preferencesId}').last;
    expect(sent.method, 'POST');
    expect(sent.queryParameters['client'], 'jellyfin-client');
    final saved = jsonDecode(((sent.data as Map)['CustomPrefs'] as Map)['rz'] as String) as Map;
    expect((saved['audio'], saved['subtitlesOff']), ('jpn', true));
  });
}
