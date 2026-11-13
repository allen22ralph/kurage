import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A media button pressed in Windows' media overlay, on the keyboard's
/// media keys (also while the app is in the background), or on the
/// taskbar thumbnail.
enum MediaButton { play, pause, next, previous, stop }

/// Windows' system media controls and taskbar thumbnail buttons (see
/// windows/runner/media_controls.cpp). Does nothing on other platforms.
class SystemMediaControls {
  SystemMediaControls._();

  static final instance = SystemMediaControls._();

  static const _channel = MethodChannel('jellyfin_client/media_controls');
  final _buttons = StreamController<MediaButton>.broadcast();
  bool _listening = false;

  bool get supported => !kIsWeb && Platform.isWindows;

  Stream<MediaButton> get buttons {
    if (supported && !_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'button') return;
        final b = MediaButton.values.where((v) => v.name == call.arguments).firstOrNull;
        if (b != null) _buttons.add(b);
      });
    }
    return _buttons.stream;
  }

  /// What's playing: shown in the media overlay; drives the thumbnail
  /// buttons (play / pause icon, previous / next enabled).
  Future<void> update({
    required String title,
    String? subtitle,
    Uri? thumbnail,
    required bool playing,
    bool canNext = false,
    bool canPrevious = false,
  }) =>
      _call('update', {
        'title': title,
        'subtitle': subtitle ?? '',
        'thumbnail': thumbnail?.toString() ?? '',
        'playing': playing,
        'canNext': canNext,
        'canPrevious': canPrevious,
      });

  /// Nothing playing: hide the overlay entry and the thumbnail buttons.
  Future<void> clear() => _call('clear');

  Future<void> _call(String method, [Object? args]) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on Object catch (e) {
      debugPrint('Media controls: $e');
    }
  }
}
