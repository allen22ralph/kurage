import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../jellyfin/client_info.dart';

const _deviceIdKey = 'device_id';
const _clientName = 'Kurage';

/// Builds the [ClientInfo] for this install.
///
/// The device ID is generated once and persisted, so the server sees the
/// same device across launches instead of piling up stale sessions.
Future<ClientInfo> loadClientInfo() async {
  final prefs = await SharedPreferences.getInstance();
  var deviceId = prefs.getString(_deviceIdKey);
  if (deviceId == null) {
    deviceId = const Uuid().v4();
    await prefs.setString(_deviceIdKey, deviceId);
  }

  final package = await PackageInfo.fromPlatform();
  return ClientInfo(
    clientName: _clientName,
    deviceName: await _deviceName(),
    deviceId: deviceId,
    version: package.version,
  );
}

Future<String> _deviceName() async {
  final info = DeviceInfoPlugin();
  try {
    if (Platform.isWindows) {
      return (await info.windowsInfo).computerName;
    }
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      return '${android.manufacturer} ${android.model}';
    }
  } catch (_) {
    // Fall through to a generic name.
  }
  return Platform.operatingSystem;
}

/// Whether this is an Android TV device (Google TV included): they all
/// declare the "leanback" system feature.
Future<bool> detectTv() async {
  if (!Platform.isAndroid) return false;
  try {
    final android = await DeviceInfoPlugin().androidInfo;
    return android.systemFeatures.contains('android.software.leanback');
  } catch (_) {
    return false;
  }
}
