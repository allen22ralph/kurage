import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/toast.dart';
import '../../app/router.dart';
import '../../app/providers.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/jellyfin_api.dart';
import '../library/library_providers.dart';
import '../../core/log/app_log.dart';

enum DownloadStatus { queued, downloading, paused, done, failed }

/// One downloaded (or downloading) episode or movie.
class DownloadRecord {
  const DownloadRecord({
    required this.itemId,
    required this.item,
    required this.fileName,
    this.status = DownloadStatus.queued,
    this.received = 0,
    this.total,
    this.error,
  });

  factory DownloadRecord.fromJson(Map<String, dynamic> j) => DownloadRecord(
    itemId: j['itemId'] as String,
    item: (j['item'] as Map).cast<String, dynamic>(),
    fileName: j['fileName'] as String,
    // A download in progress when the app closed resumes as queued.
    status: switch (DownloadStatus.values.byName(j['status'] as String)) {
      DownloadStatus.downloading => DownloadStatus.queued,
      final s => s,
    },
    received: (j['received'] as num?)?.toInt() ?? 0,
    total: (j['total'] as num?)?.toInt(),
    error: j['error'] as String?,
  );

  final String itemId;

  /// The item as the server described it, for playing offline.
  final Map<String, dynamic> item;
  final String fileName;
  final DownloadStatus status;
  final int received;
  final int? total;
  final String? error;

  BaseItem get baseItem => BaseItem.fromJson(item);
  double? get progress => total == null || total == 0 ? null : (received / total!).clamp(0.0, 1.0);

  DownloadRecord copyWith({DownloadStatus? status, int? received, int? total, String? Function()? error}) =>
      DownloadRecord(
        itemId: itemId,
        item: item,
        fileName: fileName,
        status: status ?? this.status,
        received: received ?? this.received,
        total: total ?? this.total,
        error: error == null ? this.error : error(),
      );

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'item': item,
    'fileName': fileName,
    'status': status.name,
    'received': received,
    'total': total,
    'error': error,
  };
}

/// Progress watched while the server couldn't be told (offline), to send
/// when it's back.
class PendingProgress {
  const PendingProgress({required this.itemId, required this.position, required this.finished, required this.at});

  factory PendingProgress.fromJson(Map<String, dynamic> j) => PendingProgress(
    itemId: j['itemId'] as String,
    position: Duration(milliseconds: (j['positionMs'] as num).toInt()),
    finished: j['finished'] as bool? ?? false,
    at: DateTime.parse(j['at'] as String),
  );

  final String itemId;
  final Duration position;
  final bool finished;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'positionMs': position.inMilliseconds,
    'finished': finished,
    'at': at.toUtc().toIso8601String(),
  };
}

class DownloadsState {
  const DownloadsState({this.records = const {}, this.pending = const []});

  final Map<String, DownloadRecord> records;
  final List<PendingProgress> pending;

  DownloadRecord? operator [](String itemId) => records[itemId];
}

/// Where downloads live (overridable in tests).
final downloadsDirProvider = FutureProvider<Directory>((ref) async {
  final s = ref.watch(currentSessionProvider);
  final base = await getApplicationSupportDirectory();
  // Per account: another user's downloads aren't theirs to play.
  return Directory('${base.path}${Platform.pathSeparator}downloads${Platform.pathSeparator}${s.serverId}-${s.userId}');
});

final downloadsProvider = AsyncNotifierProvider<DownloadsController, DownloadsState>(DownloadsController.new);

/// Downloads, one at a time, resuming where an interrupted one stopped.
class DownloadsController extends AsyncNotifier<DownloadsState> {
  late Directory _dir;
  CancelToken? _cancel;
  String? _active;

  /// What each "Download" asked for (a season: its episodes), to say once
  /// when all of it has finished.
  final _batches = <({String label, Set<String> left, Set<String> all})>[];

  File get _index => File('${_dir.path}${Platform.pathSeparator}index.json');
  File fileOf(DownloadRecord r) => File('${_dir.path}${Platform.pathSeparator}${r.fileName}');

  @override
  Future<DownloadsState> build() async {
    _dir = await ref.watch(downloadsDirProvider.future);
    ref.onDispose(() => _cancel?.cancel());
    var s = const DownloadsState();
    try {
      if (await _index.exists()) {
        final j = (jsonDecode(await _index.readAsString()) as Map).cast<String, dynamic>();
        s = DownloadsState(
          records: {
            for (final r in (j['records'] as List?) ?? const [])
              (r as Map)['itemId'] as String: DownloadRecord.fromJson(r.cast<String, dynamic>()),
          },
          pending: [
            for (final p in (j['pending'] as List?) ?? const [])
              PendingProgress.fromJson((p as Map).cast<String, dynamic>()),
          ],
        );
      }
    } on Object catch (e) {
      debugPrint('Downloads index: $e');
    }
    // Carry on with what was queued, and send progress made offline.
    Future.microtask(() {
      _next();
      syncPending();
    });
    return s;
  }

  Future<void> _save() async {
    final s = state.value;
    if (s == null) return;
    await _dir.create(recursive: true);
    await _index.writeAsString(
      jsonEncode({
        'records': [for (final r in s.records.values) r.toJson()],
        'pending': [for (final p in s.pending) p.toJson()],
      }),
    );
  }

  void _put(DownloadRecord r, {bool save = true}) {
    final s = state.value ?? const DownloadsState();
    state = AsyncData(DownloadsState(records: {...s.records, r.itemId: r}, pending: s.pending));
    if (save) unawaited(_save());
  }

  /// Downloads [item] (an episode or movie; a season or show: each of
  /// its episodes).
  Future<void> add(BaseItem item) async {
    final s = await future;
    final api = ref.read(libraryApiProvider);
    final List<BaseItem> items = switch (item.type) {
      ItemType.season => await api.getEpisodes(item.seriesId ?? '', seasonId: item.id),
      ItemType.series => [
        for (final season in await api.getSeasons(item.id)) ...await api.getEpisodes(item.id, seasonId: season.id),
      ],
      _ => [item],
    };
    final added = <String>{};
    for (final i in items) {
      if (s.records.containsKey(i.id)) continue;
      added.add(i.id);
      // The full item (media sources, chapters) to play it offline.
      final full = await api.getItem(i.id);
      final container = switch (full.raw['MediaSources']) {
        final List l when l.isNotEmpty => ((l.first as Map)['Container'] as String?)?.split(',').first,
        _ => null,
      };
      _put(DownloadRecord(itemId: i.id, item: full.raw, fileName: '${i.id}.${container ?? 'mkv'}'));
    }
    if (added.isNotEmpty) {
      final label = switch (item.type) {
        ItemType.season || ItemType.series =>
          item.type == ItemType.season
              ? '${item.seriesName ?? ''} · ${item.name}'.replaceFirst(RegExp(r'^ · '), '')
              : item.name,
        ItemType.episode => [item.seriesName, item.episodeLabel].nonNulls.join(' · '),
        _ => item.name,
      };
      _batches.add((label: label, left: {...added}, all: added));
    }
    _next();
  }

  /// Says (once per Download) when it's all done, or that one failed.
  void _finished(DownloadRecord r, {String? error}) {
    if (error != null) {
      final i = r.baseItem;
      final name = i.type == ItemType.episode ? [i.seriesName, i.episodeLabel].nonNulls.join(' · ') : i.name;
      showToast(
        "Couldn't download $name: $error",
        actionLabel: 'Retry',
        onAction: () => resume(r.itemId),
        duration: const Duration(seconds: 8),
      );
    }
    for (final b in [..._batches]) {
      if (!b.left.remove(r.itemId) || b.left.isNotEmpty) continue;
      _batches.remove(b);
      if (error != null && b.all.length == 1) continue;
      final failed = b.all.where((id) => state.value?[id]?.status == DownloadStatus.failed).length;
      final done = b.all.length - failed;
      if (done == 0) continue;
      showToast(
        b.all.length == 1
            ? 'Downloaded ${b.label}'
            : 'Downloaded $done episode${done == 1 ? '' : 's'} of ${b.label}${failed > 0 ? ' ($failed failed)' : ''}',
        actionLabel: b.all.length == 1 ? 'Play' : 'Open',
        // The router when tapped, not now: nothing here may stop the toast.
        onAction: () => ref.read(routerProvider).push(b.all.length == 1 ? '/play/${b.all.single}' : '/downloads'),
        duration: const Duration(seconds: 6),
        id: 'downloaded',
      );
    }
  }

  void pause(String itemId) {
    if (_active == itemId) _cancel?.cancel('paused');
    final r = state.value?[itemId];
    if (r != null && r.status != DownloadStatus.done) _put(r.copyWith(status: DownloadStatus.paused));
  }

  void resume(String itemId) {
    final r = state.value?[itemId];
    if (r != null && r.status != DownloadStatus.done) {
      _put(r.copyWith(status: DownloadStatus.queued, error: () => null));
    }
    _next();
  }

  /// Deletes the download (and its file).
  Future<void> remove(String itemId) async {
    if (_active == itemId) _cancel?.cancel('removed');
    final s = state.value;
    final r = s?[itemId];
    if (s == null || r == null) return;
    state = AsyncData(DownloadsState(records: {...s.records}..remove(itemId), pending: s.pending));
    await _save();
    try {
      final f = fileOf(r);
      if (await f.exists()) await f.delete();
    } on Object catch (e) {
      debugPrint('Delete download: $e');
    }
  }

  /// The downloaded file for [itemId], once complete.
  ({String path, Map<String, dynamic> item})? localCopy(String itemId) {
    final r = state.value?[itemId];
    if (r == null || r.status != DownloadStatus.done) return null;
    final f = fileOf(r);
    return f.existsSync() ? (path: f.path, item: r.item) : null;
  }

  /// Bytes used by downloads.
  int get bytesUsed =>
      [for (final r in state.value?.records.values ?? const <DownloadRecord>[]) r.received].fold(0, (a, b) => a + b);

  void _next() {
    if (_active != null) return;
    final s = state.value;
    final next = s?.records.values.where((r) => r.status == DownloadStatus.queued).firstOrNull;
    if (next != null) unawaited(_download(next));
  }

  Future<void> _download(DownloadRecord r) async {
    _active = r.itemId;
    final cancel = _cancel = CancelToken();
    final api = ref.read(signedInApiProvider);
    final file = fileOf(r);
    await _dir.create(recursive: true);
    // Resume from what's already on disk.
    final have = await file.exists() ? await file.length() : 0;
    _put(r.copyWith(status: DownloadStatus.downloading, received: have, error: () => null));
    AppLog.info(LogArea.downloads, 'Downloading ${r.baseItem.name} (${r.itemId})${have > 0 ? ', resuming at ${have ~/ (1024 * 1024)} MB' : ''}');
    var lastSaved = DateTime.now();
    try {
      final response = await ref
          .read(dioFactoryProvider)()
          .get<ResponseBody>(
            // The token in the header, not the address (it ends up in proxy
            // logs otherwise).
            api.resolve('/Items/${r.itemId}/Download').toString(),
            cancelToken: cancel,
            options: Options(responseType: ResponseType.stream, headers: {
              'Authorization': api.authorizationHeader,
              if (have > 0) 'Range': 'bytes=$have-',
            }),
          );
      // 206 = the rest of a partial file; 200 = the server sent it all.
      final append = have > 0 && response.statusCode == 206;
      final length = int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '');
      final total = length == null ? null : (append ? have + length : length);
      var received = append ? have : 0;
      final sink = file.openWrite(mode: append ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in response.data!.stream) {
          sink.add(chunk);
          received += chunk.length;
          final current = state.value?[r.itemId];
          if (current == null) break; // removed
          // Progress on screen often; on disk now and then.
          final save = DateTime.now().difference(lastSaved) > const Duration(seconds: 5);
          if (save) lastSaved = DateTime.now();
          _put(
            current.copyWith(received: received, total: total),
            save: save,
          );
        }
      } finally {
        await sink.close();
      }
      final current = state.value?[r.itemId];
      if (current != null) {
        _put(current.copyWith(status: DownloadStatus.done, received: received, total: received));
        AppLog.info(LogArea.downloads, 'Downloaded ${r.baseItem.name}: ${received ~/ (1024 * 1024)} MB');
        _finished(current);
      }
    } on DioException catch (e) {
      final current = state.value?[r.itemId];
      if (current != null && !CancelToken.isCancel(e)) {
        final error = switch (e.response?.statusCode) {
          401 || 403 => "This account isn't allowed to download",
          null => "Couldn't reach the server",
          final c => 'The server refused the download ($c)',
        };
        _put(current.copyWith(status: DownloadStatus.failed, error: () => error));
        AppLog.warning(LogArea.downloads, 'Download of ${r.baseItem.name} failed: $error', error: e.message);
        _finished(current, error: error);
      }
    } on FileSystemException catch (e) {
      final current = state.value?[r.itemId];
      if (current != null) {
        _put(current.copyWith(status: DownloadStatus.failed, error: () => 'Saving failed: ${e.message}'));
        AppLog.error(LogArea.downloads, 'Saving ${r.baseItem.name} failed', error: e);
        _finished(current, error: 'saving failed (${e.message})');
      }
    } finally {
      _active = null;
      _cancel = null;
      _next();
    }
  }

  // --- progress watched offline ---

  Future<void> addPending(String itemId, Duration position, bool finished) async {
    final s = await future;
    state = AsyncData(
      DownloadsState(
        records: s.records,
        pending: [
          for (final p in s.pending)
            if (p.itemId != itemId) p,
          PendingProgress(itemId: itemId, position: position, finished: finished, at: DateTime.now()),
        ],
      ),
    );
    await _save();
  }

  /// Drops [itemId]'s kept progress: the server has a newer position.
  Future<void> removePending(String itemId) async {
    final s = await future;
    if (s.pending.every((p) => p.itemId != itemId)) return;
    state = AsyncData(
      DownloadsState(records: s.records, pending: [for (final p in s.pending) if (p.itemId != itemId) p]),
    );
    await _save();
  }

  /// Sends progress made offline (each kept until the server takes it).
  Future<void> syncPending() async {
    final s = state.value;
    if (s == null || s.pending.isEmpty) return;
    final api = ref.read(signedInApiProvider);
    final userId = ref.read(currentSessionProvider).userId;
    final left = <PendingProgress>[];
    for (final p in s.pending) {
      try {
        await api.postJson(
          '/UserItems/${p.itemId}/UserData',
          query: {'userId': userId},
          body: {
            'PlaybackPositionTicks': p.finished ? 0 : p.position.inMicroseconds * 10,
            'Played': p.finished,
            'LastPlayedDate': p.at.toUtc().toIso8601String(),
          },
        );
      } on JellyfinException {
        left.add(p);
      }
    }
    final now = state.value ?? s;
    state = AsyncData(DownloadsState(records: now.records, pending: left));
    await _save();
    if (left.length < s.pending.length) refreshWatchState(ref.invalidate);
  }
}
