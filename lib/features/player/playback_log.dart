import 'package:flutter/foundation.dart';

import '../../core/log/app_log.dart';

/// What the player did lately (opening, recovering, errors), to copy into a
/// bug report after the fact. Kept in memory: the last [capacity] lines;
/// each also goes to the app log.
class PlaybackLog {
  PlaybackLog._();

  static const capacity = 80;
  static final lines = ValueNotifier<List<String>>(const []);

  static void add(String line) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final next = [...lines.value, '$stamp  $line'];
    lines.value = next.length > capacity ? next.sublist(next.length - capacity) : next;
    AppLog.info(line.startsWith('Watch together') ? LogArea.syncplay : LogArea.player, line);
  }

  static String get text => lines.value.join('\n');
}
