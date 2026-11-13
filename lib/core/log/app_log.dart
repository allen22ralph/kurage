import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel {
  debug('Debug'),
  info('Info'),
  warning('Warning'),
  error('Error');

  const LogLevel(this.label);

  final String label;

  /// One letter for the log's text form.
  String get letter => name[0].toUpperCase();
}

/// Which part of the app a line is about, to filter by.
enum LogArea {
  app('App'),
  network('Network'),
  player('Player'),
  syncplay('Watch together'),
  seerr('Seerr'),
  downloads('Downloads'),
  anime('MyAnimeList'),
  admin('Server admin'),
  navigation('Navigation'),
  notification('Notifications'),
  update('Updates');

  const LogArea(this.label);

  final String label;

  static LogArea parse(String? name) => values.firstWhere((a) => a.name == name, orElse: () => LogArea.app);
}

class LogEntry {
  const LogEntry(this.at, this.level, this.area, this.message, {this.details});

  final DateTime at;
  final LogLevel level;
  final LogArea area;
  final String message;

  /// More lines (a stack trace, a server's answer).
  final String? details;

  static String _two(int n) => n.toString().padLeft(2, '0');

  String get time => '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}.${at.millisecond.toString().padLeft(3, '0')}';

  String get date => '${at.year}-${_two(at.month)}-${_two(at.day)}';

  /// One line of the log file / a copied report; details indented below.
  String format({bool withDate = false}) {
    final head = '${withDate ? '$date ' : ''}$time ${level.letter} [${area.name}] $message';
    final more = details;
    if (more == null || more.isEmpty) return head;
    return '$head\n${more.trimRight().split('\n').map((l) => '    $l').join('\n')}';
  }

  /// Reads a line written by [format] (withDate); null if it isn't one.
  static LogEntry? parse(String line) {
    final m = RegExp(r'^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d)\.(\d{3}) ([DIWE]) \[(\w+)\] (.*)$').firstMatch(line);
    if (m == null) return null;
    final at = DateTime.tryParse('${m[1]}T${m[2]}.${m[3]}');
    if (at == null) return null;
    final level = LogLevel.values.firstWhere((l) => l.letter == m[4]);
    return LogEntry(at, level, LogArea.parse(m[5]), m[6]!);
  }
}

/// One log for the whole app (#87): what it did, what failed and why, by
/// area. Kept in memory for the viewer (Settings > Troubleshooting > App
/// log) and written to a file, so a session's log survives a restart or a
/// crash. Nothing secret goes in: requests are logged by path only (no
/// server address, no tokens).
class AppLog {
  AppLog._();

  /// Lines kept in memory.
  static const capacity = 3000;

  /// The log file is rotated at this size (one older file is kept).
  static const maxFileBytes = 1024 * 1024;

  static final entries = ValueNotifier<List<LogEntry>>(const []);

  static IOSink? _sink;

  /// Kept so it keeps listening.
  // ignore: unused_field
  static AppLifecycleListener? _lifecycle;
  static File? _file;
  static int _fileBytes = 0;

  /// The folder the log files are in (null before [init], or in tests).
  static Directory? folder;

  static void add(LogArea area, LogLevel level, String message, {Object? error, StackTrace? stack, String? details}) {
    // A message over several lines: the first is the line, the rest details.
    final cut = message.indexOf('\n');
    final rest = cut < 0 ? null : message.substring(cut + 1);
    if (cut >= 0) message = message.substring(0, cut);
    final more = [
      ?rest,
      ?details,
      if (error != null) '$error',
      if (stack != null) '$stack',
    ].join('\n');
    final entry = LogEntry(DateTime.now(), level, area, message, details: more.isEmpty ? null : more);
    final next = [...entries.value, entry];
    entries.value = next.length > capacity ? next.sublist(next.length - capacity) : next;
    if (kDebugMode) _print(entry.format());
    _write(entry);
  }

  static void debug(LogArea area, String message) => add(area, LogLevel.debug, message);
  static void info(LogArea area, String message) => add(area, LogLevel.info, message);
  static void warning(LogArea area, String message, {Object? error, StackTrace? stack}) =>
      add(area, LogLevel.warning, message, error: error, stack: stack);
  static void error(LogArea area, String message, {Object? error, StackTrace? stack}) =>
      add(area, LogLevel.error, message, error: error, stack: stack);

  /// The log as text (all of it, or [only] these lines), for a bug report.
  static String text([List<LogEntry>? only]) => (only ?? entries.value).map((e) => e.format(withDate: true)).join('\n');

  /// Forgets the lines shown (the files stay until rotated).
  static void clear() => entries.value = const [];

  /// Flutter's own printer (debugPrint itself is sent here once captured).
  /// Under `flutter test`, at once: the throttled one holds what's over
  /// its rate for a second's timer, which a test can end before.
  static final DebugPrintCallback _print =
      Platform.environment.containsKey('FLUTTER_TEST') ? debugPrintSynchronously : debugPrintThrottled;

  /// Starts the log: the file, the previous session's last lines, and the
  /// app's own messages (debugPrint) and uncaught errors.
  static Future<void> init({required String version}) async {
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}logs');
      await dir.create(recursive: true);
      folder = dir;
      final file = File('${dir.path}${Platform.pathSeparator}app.log');
      final previous = await _tail(file, 400);
      if (previous.isNotEmpty) {
        entries.value = [...previous, ...entries.value];
      }
      _file = file;
      _fileBytes = await file.exists() ? await file.length() : 0;
      _sink = file.openWrite(mode: FileMode.append);
    } on Object catch (e) {
      _print('App log: no log file ($e)');
    }
    captureAppMessages();
    // No device name: the log is meant to be pasted into bug reports.
    info(LogArea.app, 'Started: Kurage $version on ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    _lifecycle = AppLifecycleListener(onStateChange: (state) => debug(LogArea.app, 'App ${state.name}'));
  }

  /// debugPrint and uncaught errors go to the log too.
  static void captureAppMessages() {
    debugPrint = (message, {wrapWidth}) {
      if (message == null) return;
      final (area, text) = _areaOf(message);
      add(area, LogLevel.info, text);
    };
    final flutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      add(LogArea.app, LogLevel.error, 'Flutter error: ${details.exceptionAsString()}',
          details: details.stack?.toString());
      flutterError?.call(details);
    };
    final platformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      add(LogArea.app, LogLevel.error, 'Uncaught error', error: error, stack: stack);
      return platformError?.call(error, stack) ?? false;
    };
  }

  /// The area from a debugPrint's prefix ("SyncPlay: …").
  static (LogArea, String) _areaOf(String message) {
    const prefixes = {
      'MAL sync': LogArea.anime,
      'Downloads': LogArea.downloads,
      'Delete download': LogArea.downloads,
      'SyncPlay': LogArea.syncplay,
      'Stream': LogArea.player,
      'Playback': LogArea.player,
      'Fallback segments': LogArea.player,
      'Media controls': LogArea.player,
      'Mini player': LogArea.player,
      'Track choices': LogArea.player,
      'Seerr': LogArea.seerr,
    };
    for (final MapEntry(key: prefix, value: area) in prefixes.entries) {
      if (message.startsWith(prefix)) return (area, message);
    }
    return (LogArea.app, message);
  }

  static void _write(LogEntry entry) {
    final sink = _sink;
    if (sink == null) return;
    final line = '${entry.format(withDate: true)}\n';
    sink.write(line);
    _fileBytes += line.length;
    if (_fileBytes > maxFileBytes) unawaited(_rotate());
  }

  static Future<void> _rotate() async {
    final file = _file;
    final sink = _sink;
    if (file == null || sink == null) return;
    _sink = null;
    try {
      await sink.close();
      final old = File('${file.path}.1');
      if (await old.exists()) await old.delete();
      await file.rename(old.path);
      _fileBytes = 0;
      _sink = File(file.path).openWrite();
    } on Object catch (e) {
      _print('App log: rotate failed ($e)');
    }
  }

  /// The last [count] entries of the log file (a previous session's).
  static Future<List<LogEntry>> _tail(File file, int count) async {
    if (!await file.exists()) return const [];
    final lines = await file.readAsLines().catchError((Object _) => <String>[]);
    final out = <LogEntry>[];
    for (final line in lines.length > count * 3 ? lines.sublist(lines.length - count * 3) : lines) {
      final entry = LogEntry.parse(line);
      if (entry != null) out.add(entry);
    }
    return out.length > count ? out.sublist(out.length - count) : out;
  }

  /// Writes the log to a file in [dir] (e.g. Downloads) and returns it.
  static Future<File> saveTo(Directory dir, {List<LogEntry>? only}) async {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'kurage-log-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.txt';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(text(only));
    return file;
  }

  /// Writes what's waiting to the file (before the app quits).
  static Future<void> flush() async {
    try {
      await _sink?.flush();
    } on Object {
      // The file isn't needed to quit.
    }
  }

  /// For tests: back to an empty log with no file.
  @visibleForTesting
  static Future<void> reset() async {
    await _sink?.close();
    _sink = null;
    _file = null;
    folder = null;
    entries.value = const [];
  }
}
