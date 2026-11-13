import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/player/system_media_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jellyfin_client/media_controls');

  test('sends what is playing, and hears the media buttons', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final media = SystemMediaControls.instance;
    final pressed = <MediaButton>[];
    final sub = media.buttons.listen(pressed.add);

    await media.update(title: 'The Journey\'s End', subtitle: 'Frieren · S1:E1', playing: true, canNext: true);
    await media.clear();
    if (Platform.isWindows) {
      expect(calls.map((c) => c.method), ['update', 'clear']);
      expect(calls.first.arguments, containsPair('canNext', true));
      expect(calls.first.arguments, containsPair('subtitle', 'Frieren · S1:E1'));

      // The runner reports a press.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'jellyfin_client/media_controls',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('button', 'next')),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(pressed, [MediaButton.next]);
    } else {
      expect(calls, isEmpty, reason: 'Windows only');
    }
    await sub.cancel();
  });
}
