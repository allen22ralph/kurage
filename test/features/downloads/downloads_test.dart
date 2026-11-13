import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/providers.dart';
import 'package:jellyfin_client/app/toast.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/features/downloads/downloads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  late Directory dir;
  late FakeServer server;
  late ProviderContainer c;

  final episode = itemJson('ep1', 'The Journey\'s End', type: 'Episode', extra: {
    'SeriesName': 'Frieren',
    'MediaSources': [
      {'Id': 'src1', 'Container': 'mkv'},
    ],
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('downloads');
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    server = FakeServer({
      '/Items/ep1': (200, episode),
      '/Items/ep1/Download': (RequestOptions o) => o.headers['Range'] == 'bytes=6-' ? (206, 'world') : (200, 'hello world'),
      'POST /UserItems/ep1/UserData': (200, {}),
    });
    c = ProviderContainer(overrides: [
      ...fakeServerOverrides(server),
      downloadsDirProvider.overrideWith((ref) async => dir),
    ]);
    await c.read(sessionControllerProvider.future);
  });

  tearDown(() async {
    c.dispose();
    // Windows can hold a just-closed file for a moment ("being used by
    // another process"): that fails the cleanup, not the test's download.
    for (var attempt = 0; ; attempt++) {
      try {
        await dir.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  Future<DownloadRecord> waitDone() async {
    // Real file I/O: allow for a busy machine (the suite runs in parallel).
    for (var i = 0; i < 500; i++) {
      final r = c.read(downloadsProvider).value?['ep1'];
      if (r != null && (r.status == DownloadStatus.done || r.status == DownloadStatus.failed)) return r;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('download did not finish');
  }

  test('download, play from the file, delete', () async {
    final downloads = c.read(downloadsProvider.notifier);
    await c.read(downloadsProvider.future);
    await downloads.add(BaseItem.fromJson(episode));
    final r = await waitDone();
    expect((r.status, r.fileName), (DownloadStatus.done, 'ep1.mkv'));
    final local = downloads.localCopy('ep1')!;
    expect(File(local.path).readAsStringSync(), 'hello world');
    expect(local.item['SeriesName'], 'Frieren', reason: 'saved to play offline');
    final request = server.requestsTo('/Items/ep1/Download').single;
    expect(request.uri.queryParameters.containsKey('api_key'), isFalse, reason: 'not in the address (proxy logs)');
    expect(request.headers['Authorization'], contains('Token="tok"'), reason: 'the token goes in the header');

    // Survives an app restart.
    c.invalidate(downloadsProvider);
    await c.read(downloadsProvider.future);
    expect(c.read(downloadsProvider.notifier).localCopy('ep1'), isNotNull);

    await c.read(downloadsProvider.notifier).remove('ep1');
    expect(File(local.path).existsSync(), isFalse);
    expect(c.read(downloadsProvider.notifier).localCopy('ep1'), isNull);
  });

  test('a toast when the download has finished, not when it starts', () async {
    final downloads = c.read(downloadsProvider.notifier);
    await c.read(downloadsProvider.future);
    await downloads.add(BaseItem.fromJson(episode));
    await waitDone();
    expect(shownToasts, contains('Downloaded Frieren'));
    expect(shownToasts.where((t) => t.startsWith('Downloading')), isEmpty, reason: 'nothing on starting');
  }, testOn: 'windows || linux || mac-os');

  test('an interrupted download resumes where it stopped', () async {
    await Directory(dir.path).create(recursive: true);
    File('${dir.path}${Platform.pathSeparator}ep1.mkv').writeAsStringSync('hello ');
    final downloads = c.read(downloadsProvider.notifier);
    await c.read(downloadsProvider.future);
    await downloads.add(BaseItem.fromJson(episode));
    await waitDone();
    expect(File(downloads.localCopy('ep1')!.path).readAsStringSync(), 'hello world');
    expect(server.requestsTo('/Items/ep1/Download').single.headers['Range'], 'bytes=6-');
  });

  test('progress watched offline is sent when the server is back', () async {
    final downloads = c.read(downloadsProvider.notifier);
    await c.read(downloadsProvider.future);
    server.routes['POST /UserItems/ep1/UserData'] = (-1, null); // offline
    await downloads.addPending('ep1', const Duration(minutes: 12), false);
    await downloads.syncPending();
    expect(c.read(downloadsProvider).value!.pending, hasLength(1), reason: 'kept while offline');

    server.routes['POST /UserItems/ep1/UserData'] = (200, {});
    await downloads.syncPending();
    expect(c.read(downloadsProvider).value!.pending, isEmpty);
    final sent = server.requestsTo('/UserItems/ep1/UserData').last.data as Map;
    expect((sent['PlaybackPositionTicks'], sent['Played']), (const Duration(minutes: 12).inMicroseconds * 10, false));
  });
}
