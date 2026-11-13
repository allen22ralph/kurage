import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/settings/playback_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('hardware decoding: copy back by default (as Jellyfin Media Player), and the choice is kept', () async {
    SharedPreferences.setMockInitialValues({});
    var c = ProviderContainer();
    final settings = await c.read(playbackSettingsProvider.future);
    expect(settings.hardwareDecoding, HardwareDecoding.copy);
    expect(HardwareDecoding.copy.mpv, 'auto-copy');
    await c.read(playbackSettingsProvider.notifier).save(settings.copyWith(hardwareDecoding: HardwareDecoding.off));
    c.dispose();

    c = ProviderContainer();
    addTearDown(c.dispose);
    expect((await c.read(playbackSettingsProvider.future)).hardwareDecoding, HardwareDecoding.off);
  });
}
