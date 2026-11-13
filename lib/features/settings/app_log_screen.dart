import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/toast.dart';
import '../../core/log/app_log.dart';

/// The app log (#87): filter by area, level and text; Copy for a bug
/// report, Save to a file (desktop), Clear. Newest at the bottom; tap a line
/// with details (a stack trace, the server's answer) to see them.
class AppLogScreen extends StatefulWidget {
  const AppLogScreen({super.key});

  @override
  State<AppLogScreen> createState() => _AppLogScreenState();
}

class _AppLogScreenState extends State<AppLogScreen> {
  LogLevel _min = LogLevel.info;
  final Set<LogArea> _areas = {};
  final _find = TextEditingController();
  final Set<LogEntry> _open = {};

  @override
  void dispose() {
    _find.dispose();
    super.dispose();
  }

  List<LogEntry> _filter(List<LogEntry> all) {
    final q = _find.text.trim().toLowerCase();
    return [
      for (final e in all)
        if (e.level.index >= _min.index &&
            (_areas.isEmpty || _areas.contains(e.area)) &&
            (q.isEmpty || e.message.toLowerCase().contains(q) || (e.details?.toLowerCase().contains(q) ?? false)))
          e,
    ];
  }

  Future<void> _save(List<LogEntry> shown) async {
    try {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      final file = await AppLog.saveTo(dir, only: shown);
      showToast(
        'Saved ${file.uri.pathSegments.last} to ${dir.path}',
        actionLabel: 'Open folder',
        onAction: () => launchUrl(Uri.directory(dir.path)),
      );
    } on Object catch (e) {
      showToast("Couldn't save the log: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<List<LogEntry>>(
      valueListenable: AppLog.entries,
      builder: (context, all, _) {
        final shown = _filter(all);
        return Scaffold(
          appBar: AppBar(
            title: const Text('App log'),
            actions: [
              PopupMenuButton<LogLevel>(
                tooltip: 'Show from level',
                initialValue: _min,
                icon: const Icon(Icons.filter_list),
                onSelected: (l) => setState(() => _min = l),
                itemBuilder: (_) => [
                  for (final l in LogLevel.values)
                    CheckedPopupMenuItem(value: l, checked: l == _min, child: Text('${l.label} and up')),
                ],
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_all_outlined),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: AppLog.text(shown)));
                  showToast('Copied ${shown.length} lines of the log');
                },
              ),
              // Saving to a file: desktop (on phones, Copy into the report).
              if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                IconButton(tooltip: 'Save to a file', icon: const Icon(Icons.save_alt), onPressed: () => _save(shown)),
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => setState(AppLog.clear),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  controller: _find,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Find in the log',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                  ),
                ),
              ),
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  children: [
                    for (final a in LogArea.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: Text(a.label),
                          selected: _areas.contains(a),
                          onSelected: (on) => setState(() => on ? _areas.add(a) : _areas.remove(a)),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: shown.isEmpty
                    ? Center(child: Text(all.isEmpty ? 'Nothing logged yet.' : 'No lines match.'))
                    // Newest at the bottom, scrolled there to start with.
                    : ListView.builder(
                        reverse: true,
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final e = shown[shown.length - 1 - i];
                          return _Line(
                            entry: e,
                            open: _open.contains(e),
                            onTap: e.details == null
                                ? null
                                : () => setState(() => _open.contains(e) ? _open.remove(e) : _open.add(e)),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: Text(
                  '${shown.length} of ${all.length} lines. Kept across restarts; requests show their path only (no server address or tokens).',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.entry, required this.open, this.onTap});

  final LogEntry entry;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (icon, color) = switch (entry.level) {
      LogLevel.debug => (Icons.circle_outlined, colors.outline),
      LogLevel.info => (Icons.info_outline, colors.primary),
      LogLevel.warning => (Icons.warning_amber, Colors.orange),
      LogLevel.error => (Icons.error_outline, colors.error),
    };
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 1, right: 6), child: Icon(icon, size: 14, color: color)),
                // The date only for earlier days (a previous session's lines).
                Text('${DateUtils.isSameDay(entry.at, DateTime.now()) ? '' : '${entry.date} '}${entry.time}  ',
                    style: mono?.copyWith(color: colors.onSurfaceVariant)),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '${entry.area.label}  ', style: TextStyle(color: colors.tertiary)),
                      TextSpan(text: entry.message),
                    ]),
                    style: mono,
                  ),
                ),
                if (onTap != null) Icon(open ? Icons.expand_less : Icons.expand_more, size: 16, color: colors.outline),
              ],
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 0, 4),
                child: SelectableText(entry.details!, style: mono?.copyWith(color: colors.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }
}
