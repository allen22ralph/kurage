import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// System volume and screen brightness (0.0–1.0) on Android, for the
/// player's swipe gestures. Brightness only changes the app's window and is
/// reset when the player closes.
class DeviceLevels {
  const DeviceLevels();

  static const _channel = MethodChannel('jellyfin_client/device');
  static const _volumeEvents = EventChannel('jellyfin_client/volume');

  /// The media volume whenever it changes (volume keys, other apps).
  Stream<double> volumeChanges() =>
      _volumeEvents.receiveBroadcastStream().map((v) => (v as num).toDouble());

  Future<double> volume() => _get('getVolume');
  Future<double> brightness() => _get('getBrightness');

  Future<void> setVolume(double value) => _call('setVolume', value);
  Future<void> setBrightness(double value) => _call('setBrightness', value);
  Future<void> resetBrightness() => _call('resetBrightness');

  Future<double> _get(String method) async {
    try {
      return await _channel.invokeMethod<double>(method) ?? 0.5;
    } on Object catch (e) {
      debugPrint('$method: $e');
      return 0.5;
    }
  }

  Future<void> _call(String method, [double? value]) async {
    try {
      await _channel.invokeMethod<void>(method, value);
    } on Object catch (e) {
      debugPrint('$method: $e');
    }
  }
}
