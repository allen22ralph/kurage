import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../core/log/app_log.dart';
import '../../core/update/app_update.dart';

/// The version running now (from the install's identity).
final currentVersionProvider = Provider<AppVersion>((ref) {
  String version;
  try {
    version = ref.watch(clientInfoProvider).version;
  } on UnimplementedError {
    version = ''; // tests without an install identity
  }
  return AppVersion.tryParse(version) ?? const AppVersion(0, 0, 0);
});

/// How often the app looks for a new version by itself. Every start always
/// looks (except [manual]).
enum UpdateFrequency {
  eachStart('Each start', null),
  hourly('Every hour', Duration(hours: 1)),
  sixHours('Every 6 hours', Duration(hours: 6)),
  daily('Daily', Duration(days: 1)),
  manual('Only when I check', null);

  const UpdateFrequency(this.label, this.every);

  final String label;

  /// Between checks while the app runs (and on coming back to it); null:
  /// only at start (or never, for [manual]).
  final Duration? every;
}

/// Settings > About > Updates.
class UpdateSettings {
  const UpdateSettings({required this.channel, this.frequency = UpdateFrequency.sixHours, this.notify = true});

  final UpdateChannel channel;
  final UpdateFrequency frequency;

  /// A notification (toast and the bell) for a new version, at every start
  /// until it's installed. Off: only Settings > About says so.
  final bool notify;

  bool get autoCheck => frequency != UpdateFrequency.manual;

  UpdateSettings copyWith({UpdateChannel? channel, UpdateFrequency? frequency, bool? notify}) => UpdateSettings(
        channel: channel ?? this.channel,
        frequency: frequency ?? this.frequency,
        notify: notify ?? this.notify,
      );
}

final updateSettingsProvider =
    AsyncNotifierProvider<UpdateSettingsController, UpdateSettings>(UpdateSettingsController.new);

class UpdateSettingsController extends AsyncNotifier<UpdateSettings> {
  static const _prefix = 'update.';

  /// Before a choice: the channel of the version installed (a beta stays on
  /// betas).
  UpdateChannel get _default => ref.read(currentVersionProvider).isPrerelease ? UpdateChannel.beta : UpdateChannel.stable;

  @override
  Future<UpdateSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    // Before the frequency: checking automatically on / off.
    final old = prefs.getBool('${_prefix}autoCheck') == false ? UpdateFrequency.manual : UpdateFrequency.sixHours;
    return UpdateSettings(
      channel: UpdateChannel.values.where((c) => c.name == prefs.getString('${_prefix}channel')).firstOrNull ?? _default,
      frequency: UpdateFrequency.values.where((f) => f.name == prefs.getString('${_prefix}frequency')).firstOrNull ?? old,
      notify: prefs.getBool('${_prefix}notify') ?? true,
    );
  }

  Future<void> save(UpdateSettings settings) async {
    final previous = await future.catchError((Object _) => UpdateSettings(channel: _default));
    state = AsyncData(settings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}channel', settings.channel.name);
    await prefs.setString('${_prefix}frequency', settings.frequency.name);
    await prefs.setBool('${_prefix}notify', settings.notify);
    // Another channel may have another newest version.
    if (previous.channel != settings.channel) unawaited(ref.read(updateCheckProvider.notifier).check());
  }
}

final releasesApiProvider = Provider<ReleasesApi>((ref) => ReleasesApi(dio: ref.watch(dioFactoryProvider)()));

/// What the last check found.
class UpdateStatus {
  const UpdateStatus({this.checking = false, this.checkedAt, this.available, this.error});

  final bool checking;
  final DateTime? checkedAt;

  /// A newer version on the chosen channel; null when up to date.
  final AppRelease? available;
  final String? error;
}

final updateCheckProvider = NotifierProvider<UpdateCheck, UpdateStatus>(UpdateCheck.new);

class UpdateCheck extends Notifier<UpdateStatus> {
  @override
  UpdateStatus build() => const UpdateStatus();

  /// Asks GitHub for the releases; returns the newer one, if any.
  Future<AppRelease?> check() async {
    if (state.checking) return state.available;
    state = UpdateStatus(checking: true, checkedAt: state.checkedAt, available: state.available);
    try {
      final settings = await ref.read(updateSettingsProvider.future);
      final releases = await ref.read(releasesApiProvider).releases();
      final newer = newerRelease(releases, ref.read(currentVersionProvider), settings.channel);
      state = UpdateStatus(checkedAt: DateTime.now(), available: newer);
      AppLog.info(LogArea.update, newer == null ? 'Up to date (${settings.channel.label})' : '${newer.tag} is available');
      return newer;
    } catch (e) {
      final message = e is DioException && e.response?.statusCode == 404
          ? 'No releases found'
          : e is DioException && e.response?.statusCode == 403
              ? 'GitHub is limiting checks; try again later'
              : "Couldn't reach GitHub";
      AppLog.warning(LogArea.update, 'Update check failed: $message', error: e);
      state = UpdateStatus(checkedAt: state.checkedAt, available: state.available, error: message);
      return null;
    }
  }
}

/// How the update went (or why it couldn't start).
enum InstallResult {
  /// Android's installer is open, or (Windows) the app is about to restart.
  started,

  /// Android: installing from this app needs allowing first (its settings
  /// page is open).
  needsPermission,

  /// Windows: the app's folder can't be written (e.g. in Program Files).
  notWritable,

  /// This release has no file for this device.
  noFile,
}

/// Downloads a release's file for this device and installs it.
class UpdateInstaller {
  const UpdateInstaller();

  static const _channel = MethodChannel('jellyfin_client/device');

  /// Files already downloaded and checked this run, by address: going on
  /// after allowing installs (Android) doesn't download again.
  static final _downloaded = <Uri, File>{};

  /// Android: whether this app may hand APKs to the installer yet.
  Future<bool> canInstall() async =>
      !Platform.isAndroid || (await _channel.invokeMethod<bool>('canInstallApks') ?? false);

  /// The phone's ABIs, best first (Android); empty elsewhere.
  Future<List<String>> abis() async =>
      Platform.isAndroid ? (await DeviceInfoPlugin().androidInfo).supportedAbis : const [];

  Future<InstallResult> install(AppRelease release, {void Function(double progress)? onProgress}) async {
    final asset = release.assetFor(android: Platform.isAndroid, abis: await abis());
    if (asset == null) return InstallResult.noFile;
    final appDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isWindows && !await _writable(appDir)) return InstallResult.notWritable;

    final file = await _download(asset, onProgress);
    _downloaded[asset.url] = file;

    if (Platform.isAndroid) {
      final result = await _channel.invokeMethod<String>('installApk', file.path);
      AppLog.info(LogArea.update, 'Installer: $result');
      return result == 'permission' ? InstallResult.needsPermission : InstallResult.started;
    }
    await _restartInto(file, appDir);
    return InstallResult.started;
  }

  static Future<File> _download(ReleaseAsset asset, void Function(double progress)? onProgress) async {
    final ready = _downloaded[asset.url];
    if (ready != null && await ready.exists()) {
      onProgress?.call(1);
      return ready;
    }
    // Android shares it with the installer from cache/updates/ (update_paths.xml).
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');
    AppLog.info(LogArea.update, 'Downloading ${asset.name}');
    await Dio().downloadUri(
      asset.url,
      file.path,
      onReceiveProgress: (got, total) {
        final size = total > 0 ? total : asset.size;
        if (size > 0) onProgress?.call(got / size);
      },
    );
    if (asset.sha256 case final expected?) {
      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (actual != expected) {
        await file.delete();
        throw StateError("The download doesn't match the release (checksum)");
      }
    }
    return file;
  }

  static Future<bool> _writable(Directory dir) async {
    try {
      final probe = File('${dir.path}${Platform.pathSeparator}.update-check');
      await probe.writeAsString('');
      await probe.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Windows: a script waits for the app to close, unpacks the zip over its
  /// folder and opens it again. The app then quits.
  static Future<void> _restartInto(File zip, Directory appDir) async {
    String quote(String s) => "'${s.replaceAll("'", "''")}'";
    final log = '${zip.parent.path}\\update.log';
    final script = File('${zip.parent.path}\\update.ps1');
    await script.writeAsString(windowsUpdateScript(
      pid: pid,
      zip: quote(zip.path),
      dir: quote(appDir.path),
      exe: quote(Platform.resolvedExecutable),
      log: quote(log),
    ));
    AppLog.info(LogArea.update, 'Restarting to update ${appDir.path}');
    await AppLog.flush();
    // Through `start`: PowerShell started straight from the app (detached
    // or not) was ended with it, before it had unpacked anything.
    await Process.start(
      'cmd.exe',
      [
        '/c', 'start', '""', '/min', //
        'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path,
      ],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}

/// The Windows update script (paths already quoted for PowerShell).
@visibleForTesting
String windowsUpdateScript({
  required int pid,
  required String zip,
  required String dir,
  required String exe,
  required String log,
}) =>
    '''
\$ErrorActionPreference = 'Stop'
try {
  Wait-Process -Id $pid -Timeout 30 -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
  Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
  Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
  "Updated \$(Get-Date)" | Out-File -LiteralPath $log
} catch {
  "Update failed \$(Get-Date): \$_" | Out-File -LiteralPath $log
}
Start-Process -FilePath $exe
''';

final updateInstallerProvider = Provider<UpdateInstaller>((ref) => const UpdateInstaller());
