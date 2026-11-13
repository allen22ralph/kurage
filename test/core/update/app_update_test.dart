import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/update/app_update.dart';

import '../../support/fake_server.dart';

AppVersion v(String s) => AppVersion.tryParse(s)!;

Map<String, Object?> releaseJson(String tag, {bool prerelease = false, bool draft = false}) => {
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'body': 'Notes for $tag',
      'html_url': 'https://github.com/$releasesRepo/releases/tag/$tag',
      'published_at': '2026-10-01T10:00:00Z',
      'assets': [
        {
          'name': 'kurage-android-arm64-v8a-release.apk',
          'browser_download_url': 'https://github.com/x/$tag/arm64.apk',
          'size': 40,
          'digest': 'sha256:ABC',
        },
        {'name': 'kurage-android-armeabi-v7a-release.apk', 'browser_download_url': 'https://github.com/x/v7.apk'},
        {'name': 'kurage-windows-x64.zip', 'browser_download_url': 'https://github.com/x/win.zip', 'size': 90},
      ],
    };

void main() {
  group('AppVersion', () {
    test('reads versions and tags', () {
      expect(v('0.3.2').toString(), '0.3.2');
      expect(v('v0.3.2-beta.3').toString(), '0.3.2-beta.3');
      expect(v('v0.3.2-beta.3-local').toString(), '0.3.2-beta.3', reason: '-local only says where it was built');
      expect(v('0.3.2+2058').toString(), '0.3.2', reason: 'the build number is dropped');
      expect(v('0.3.2-beta.3').isPrerelease, isTrue);
      expect(AppVersion.tryParse('beta-0.3.2-1'), isNull);
      expect(AppVersion.tryParse(''), isNull);
    });

    test('orders like semantic versions: a release after its betas', () {
      final sorted = ['0.3.2', '0.3.2-beta.10', '0.2.5', '0.3.10', '0.3.2-beta.2', '1.0.0-beta.1', '0.3.2-beta.3']
          .map(v)
          .toList()
        ..sort();
      expect(sorted.map((e) => '$e'), [
        '0.2.5',
        '0.3.2-beta.2',
        '0.3.2-beta.3',
        '0.3.2-beta.10',
        '0.3.2',
        '0.3.10',
        '1.0.0-beta.1',
      ]);
      expect(v('v0.3.2-beta.3-local') == v('0.3.2-beta.3'), isTrue);
    });
  });

  group('newerRelease', () {
    final releases = [
      for (final j in [releaseJson('v0.3.3-beta.1', prerelease: true), releaseJson('v0.3.2'), releaseJson('v0.3.1')])
        AppRelease.fromGitHub(j)!,
    ];

    test('Stable skips betas; Beta takes the newest of either', () {
      expect(newerRelease(releases, v('0.3.1'), UpdateChannel.stable)?.tag, 'v0.3.2');
      expect(newerRelease(releases, v('0.3.1'), UpdateChannel.beta)?.tag, 'v0.3.3-beta.1');
      expect(newerRelease(releases, v('0.3.2'), UpdateChannel.stable), isNull, reason: 'up to date');
      expect(newerRelease(releases, v('0.3.2-beta.3'), UpdateChannel.stable)?.tag, 'v0.3.2',
          reason: 'a beta tester moving to Stable gets the release');
      expect(newerRelease(releases, v('0.3.3-beta.1'), UpdateChannel.beta), isNull);
    });

    test('a newer stable release beats an older beta on the Beta channel', () {
      final withOldBeta = [...releases, AppRelease.fromGitHub(releaseJson('v0.3.2-beta.3-local'))!];
      expect(newerRelease(withOldBeta, v('0.3.2-beta.2'), UpdateChannel.beta)?.tag, 'v0.3.3-beta.1');
      expect(newerRelease(withOldBeta.skip(1).toList(), v('0.3.2-beta.2'), UpdateChannel.beta)?.tag, 'v0.3.2');
    });
  });

  test('drafts and non-version tags are left out', () {
    expect(AppRelease.fromGitHub(releaseJson('v0.4.0', draft: true)), isNull);
    expect(AppRelease.fromGitHub(releaseJson('beta-0.3.2-1')), isNull);
  });

  test("each device's file", () {
    final r = AppRelease.fromGitHub(releaseJson('v0.3.2'))!;
    expect(r.assetFor(android: false)?.name, 'kurage-windows-x64.zip');
    final apk = r.assetFor(android: true, abis: ['arm64-v8a', 'armeabi-v7a'])!;
    expect(apk.name, 'kurage-android-arm64-v8a-release.apk');
    expect(apk.sha256, 'abc');
    expect(r.assetFor(android: true, abis: ['armeabi-v7a'])?.name, contains('armeabi-v7a'));
    expect(r.assetFor(android: true, abis: ['x86']), isNull);
  });

  test('ReleasesApi reads the public releases repo', () async {
    final server = FakeServer({
      'https://api.github.com/repos/$releasesRepo/releases': (200, [
        releaseJson('v0.3.3-beta.1', prerelease: true),
        releaseJson('v0.4.0', draft: true),
        releaseJson('v0.3.2'),
      ]),
    });
    final releases = await ReleasesApi(dio: Dio()..httpClientAdapter = server).releases();
    expect(releases.map((r) => r.tag), ['v0.3.3-beta.1', 'v0.3.2']);
    expect(releases.first.notes, 'Notes for v0.3.3-beta.1');
    expect(server.requests.single.headers['Authorization'], isNull, reason: 'no token');
  });
}
