import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/seerr/seerr_api.dart';
import '../../core/log/app_log.dart';

/// Whether Seerr answered lately: false after a failure (unreachable, or
/// Seerr itself couldn't reach TMDB), true again on the next success. Home
/// says so while it's down; rows retry by themselves meanwhile.
final seerrReachableProvider = NotifierProvider<SeerrReachable, bool>(SeerrReachable.new);

class SeerrReachable extends Notifier<bool> {
  @override
  bool build() => true;

  void report({required bool ok}) {
    if (state == ok) return;
    state = ok;
    // Kept in the log, even if the note on Home was missed.
    AppLog.add(LogArea.seerr, ok ? LogLevel.info : LogLevel.warning, ok ? 'Seerr is reachable again' : "Seerr isn't reachable");
  }
}

/// A failure worth retrying: no answer, or Seerr's own 5xx (e.g. it lost its
/// connection, as behind a VPN container that reconnects). Not "signed out"
/// or "not found".
bool seerrTransient(Object error) =>
    error is! SeerrException || error.statusCode == null || error.statusCode! >= 500;

/// Retry delays for Seerr rows: 5 s, 15 s, 30 s, then every minute, for as
/// long as the row is shown.
Duration seerrRetryDelay(int attempt) => Duration(seconds: const [5, 15, 30, 60][math.min(attempt, 3)]);

/// For FutureProvider's `retry:`.
Duration? seerrRetry(int attempt, Object error) => seerrTransient(error) ? seerrRetryDelay(attempt) : null;

/// Runs [request], telling [reachable] (seerrReachableProvider's notifier)
/// how it went.
Future<T> trackSeerr<T>(SeerrReachable Function() reachable, Future<T> request) async {
  try {
    final result = await request;
    // Not during a provider's own build.
    scheduleMicrotask(() => _report(reachable, ok: true));
    return result;
  } on Object catch (e) {
    if (seerrTransient(e)) scheduleMicrotask(() => _report(reachable, ok: false));
    rethrow;
  }
}

/// Tells [reachable] how a request went, unless the provider that asked is
/// gone by then (a row rebuilt while Seerr was timing out): reading through
/// its ref would throw ("used after it has been disposed").
void _report(SeerrReachable Function() reachable, {required bool ok}) {
  final SeerrReachable notifier;
  try {
    notifier = reachable();
  } on Object {
    return;
  }
  notifier.report(ok: ok);
}

/// At most a few Seerr requests at a time from the generated rows, so a
/// screenful of them doesn't hit Seerr (and its DNS) all at once.
class SeerrSlots {
  SeerrSlots(this.size);

  final int size;
  int _busy = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_busy >= size) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _busy++;
    try {
      return await task();
    } finally {
      _busy--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

final seerrSlotsProvider = Provider<SeerrSlots>((_) => SeerrSlots(3));
