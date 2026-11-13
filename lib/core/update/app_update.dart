import 'package:dio/dio.dart';

import '../log/app_log.dart';
import '../log/log_interceptor.dart';

/// Where the app's builds are published: a public repo with only releases
/// (the code's repo is private, and reading its releases needs a token).
const releasesRepo = 'allen22ralph/kurage';

/// Which releases the app offers: Stable only, or betas too.
enum UpdateChannel {
  stable('Stable'),
  beta('Beta');

  const UpdateChannel(this.label);

  final String label;
}

/// An app version: `0.3.2`, `0.3.2-beta.3`, or a tag (`v0.3.2-beta.3-local`;
/// the `v` and `-local`, which only says where it was built, are dropped).
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.pre = const []]);

  final int major;
  final int minor;
  final int patch;

  /// What follows the `-` (`['beta', '3']`); empty for a release.
  final List<String> pre;

  bool get isPrerelease => pre.isNotEmpty;

  static final _pattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$');

  /// Null when [text] isn't a version.
  static AppVersion? tryParse(String text) {
    final m = _pattern.firstMatch(text.trim());
    if (m == null) return null;
    var pre = m[4]?.split(RegExp('[.-]')).where((p) => p.isNotEmpty).toList() ?? <String>[];
    if (pre.isNotEmpty && pre.last == 'local') pre = pre.sublist(0, pre.length - 1);
    return AppVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), pre);
  }

  /// Semantic-version order: a release comes after its betas.
  @override
  int compareTo(AppVersion other) {
    for (final (a, b) in [(major, other.major), (minor, other.minor), (patch, other.patch)]) {
      if (a != b) return a.compareTo(b);
    }
    if (pre.isEmpty || other.pre.isEmpty) return other.pre.length.sign - pre.length.sign;
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = int.tryParse(pre[i]), b = int.tryParse(other.pre[i]);
      final c = switch ((a, b)) {
        (final a?, final b?) => a.compareTo(b),
        (_?, null) => -1,
        (null, _?) => 1,
        _ => pre[i].compareTo(other.pre[i]),
      };
      if (c != 0) return c;
    }
    return pre.length.compareTo(other.pre.length);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre.join('.'));

  @override
  String toString() => '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}

/// A file on a release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, required this.size, this.sha256});

  final String name;
  final Uri url;
  final int size;

  /// From GitHub's `digest` (`sha256:…`), when it gives one.
  final String? sha256;

  factory ReleaseAsset.fromGitHub(Map<String, dynamic> j) {
    final digest = j['digest'] as String?;
    return ReleaseAsset(
      name: j['name'] as String,
      url: Uri.parse(j['browser_download_url'] as String),
      size: (j['size'] as num?)?.toInt() ?? 0,
      sha256: digest != null && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
    );
  }
}

/// A published release.
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.version,
    required this.notes,
    required this.page,
    this.publishedAt,
    this.assets = const [],
  });

  final String tag;
  final AppVersion version;

  /// What's new (Markdown, shown as text).
  final String notes;

  /// The release's page on GitHub.
  final Uri page;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  bool get isBeta => version.isPrerelease;

  /// Null for drafts and tags that aren't versions.
  static AppRelease? fromGitHub(Map<String, dynamic> j) {
    if (j['draft'] == true) return null;
    final tag = j['tag_name'] as String? ?? '';
    final version = AppVersion.tryParse(tag);
    if (version == null) return null;
    return AppRelease(
      tag: tag,
      version: version,
      notes: (j['body'] as String? ?? '').trim(),
      page: Uri.parse(j['html_url'] as String? ?? 'https://github.com/$releasesRepo/releases'),
      publishedAt: DateTime.tryParse(j['published_at'] as String? ?? ''),
      assets: [for (final a in j['assets'] as List? ?? const []) ReleaseAsset.fromGitHub(a as Map<String, dynamic>)],
    );
  }

  /// This device's file: the Windows zip, or the APK for the first of the
  /// phone's [abis] (best first) that has one. Null when there's none.
  ReleaseAsset? assetFor({required bool android, List<String> abis = const []}) {
    if (!android) return assets.where((a) => a.name.endsWith('-windows-x64.zip')).firstOrNull;
    for (final abi in abis) {
      final apk = assets.where((a) => a.name.endsWith('-$abi-release.apk')).firstOrNull;
      if (apk != null) return apk;
    }
    return null;
  }
}

/// The newest of [releases] on [channel] (Stable: releases only; Beta:
/// betas too), when it's newer than [current]. Null when up to date.
AppRelease? newerRelease(List<AppRelease> releases, AppVersion current, UpdateChannel channel) {
  AppRelease? best;
  for (final r in releases) {
    if (channel == UpdateChannel.stable && r.isBeta) continue;
    if (best == null || r.version > best.version) best = r;
  }
  return best != null && best.version > current ? best : null;
}

/// Reads the releases from GitHub (no sign-in: the releases repo is public;
/// GitHub allows 60 such requests an hour per address).
class ReleasesApi {
  ReleasesApi({Dio? dio})
      : _dio = (dio ?? Dio())
          ..options.baseUrl = 'https://api.github.com'
          ..options.connectTimeout = const Duration(seconds: 10)
          ..options.headers['Accept'] = 'application/vnd.github+json'
          ..interceptors.add(AppLogInterceptor(LogArea.update));

  final Dio _dio;

  /// The latest releases, newest first.
  Future<List<AppRelease>> releases() async {
    final res = await _dio.get<List<dynamic>>('/repos/$releasesRepo/releases', queryParameters: {'per_page': 30});
    return [
      for (final j in res.data ?? const [])
        ?AppRelease.fromGitHub(j as Map<String, dynamic>),
    ];
  }
}
