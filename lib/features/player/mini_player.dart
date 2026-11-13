import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Picture-in-picture on Windows: the window becomes a small, always-on-top
/// 16:9 window in the corner of the screen (see windows/runner/window_mode.cpp).
class MiniPlayer {
  MiniPlayer._();

  static const _channel = MethodChannel('jellyfin_client/window');

  static bool get supported => !kIsWeb && Platform.isWindows;

  static Future<void> enter({int width = 480, int height = 270}) => _call('enterMini', {'width': width, 'height': height});

  /// Back to the window's size and place before [enter].
  static Future<void> exit() => _call('exitMini');

  /// Around fullscreen: a maximized window is restored first (fullscreen
  /// misjudges it, leaving a black band) and maximized again after; then
  /// the window's real size is passed on again.
  static Future<void> beforeFullscreen() => _call('beforeFullscreen');
  static Future<void> afterFullscreen() => _call('afterFullscreen');
  static Future<void> relayout() => _call('relayout');

  static Future<void> _call(String method, [Object? args]) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<Object?>(method, args);
    } on Object catch (e) {
      debugPrint('Mini player: $e');
    }
  }
}
