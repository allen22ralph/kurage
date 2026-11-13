import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app/click_log.dart';
import 'app/app.dart';
import 'app/layout.dart';
import 'app/providers.dart';
import 'core/device/device_identity.dart';
import 'core/net/trusted_certificates.dart';
import 'core/log/app_log.dart';
import 'features/library/widgets/action_menu.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // A menu opened by holding the mouse opens where it is, as right-click's.
  trackMousePresses();
  final clientInfo = await loadClientInfo();
  await AppLog.init(version: clientInfo.version);
  if (const bool.fromEnvironment('FRAME_LOG')) _logFrames();
  if (const bool.fromEnvironment('CLICK_LOG')) logClicks();
  final isTv = await detectTv();
  // Before any connection: private CAs the user trusts (e.g. Caddy's).
  applyTrustedCertificates(await TrustedCertificateStore().load());
  runApp(
    ProviderScope(
      overrides: [
        clientInfoProvider.overrideWithValue(clientInfo),
        isTvProvider.overrideWithValue(isTv),
      ],
      child: const JellyfinClientApp(),
    ),
  );
}

/// Test builds (--dart-define=FRAME_LOG=true): frame times in the log every
/// two seconds while frames are drawn.
void _logFrames() {
  final build = <int>[];
  final raster = <int>[];
  var since = DateTime.now();
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      build.add(t.buildDuration.inMicroseconds);
      raster.add(t.rasterDuration.inMicroseconds);
    }
    if (DateTime.now().difference(since).inSeconds < 2 || build.isEmpty) return;
    String stats(List<int> v) {
      v.sort();
      final avg = v.reduce((a, b) => a + b) / v.length / 1000;
      return 'avg ${avg.toStringAsFixed(1)} p90 ${(v[(v.length * 0.9).floor().clamp(0, v.length - 1)] / 1000).toStringAsFixed(1)} max ${(v.last / 1000).toStringAsFixed(1)} ms';
    }

    final slow = [for (var i = 0; i < build.length; i++) if (build[i] + raster[i] > 16700) i].length;
    AppLog.info(LogArea.app, 'Frames: ${build.length}, slow $slow; build ${stats(build)}; raster ${stats(raster)}');
    build.clear();
    raster.clear();
    since = DateTime.now();
  });
}
