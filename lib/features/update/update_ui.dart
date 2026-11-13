import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_dropdown.dart';
import '../../app/toast.dart';
import '../../core/time_ago.dart';
import '../../core/update/app_update.dart';
import 'updater.dart';

/// Settings > About > Updates: the channel, automatic checks, and checking
/// now.
class UpdatesSection extends ConsumerWidget {
  const UpdatesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(updateSettingsProvider).value;
    final status = ref.watch(updateCheckProvider);
    final current = ref.watch(currentVersionProvider);
    final controller = ref.read(updateSettingsProvider.notifier);
    final available = status.available;
    final String subtitle;
    if (status.checking) {
      subtitle = 'Checking…';
    } else if (available != null) {
      subtitle = 'Version ${available.version} is available (you have $current)';
    } else if (status.error != null) {
      subtitle = "Couldn't check: ${status.error}";
    } else if (status.checkedAt != null) {
      subtitle = 'Up to date ($current) · checked ${timeAgo(status.checkedAt!)}';
    } else {
      subtitle = 'You have $current';
    }
    return Column(
      children: [
        if (settings != null) ...[
          ListTile(
            title: const Text('Update channel'),
            subtitle: Text(settings.channel == UpdateChannel.beta
                ? 'Betas too: new things first, and maybe new bugs'
                : 'Tested releases only'),
            trailing: SegmentedButton<UpdateChannel>(
              showSelectedIcon: false,
              segments: [for (final c in UpdateChannel.values) ButtonSegment(value: c, label: Text(c.label))],
              selected: {settings.channel},
              onSelectionChanged: (c) => controller.save(settings.copyWith(channel: c.first)),
            ),
          ),
          ListTile(
            title: const Text('Check automatically'),
            subtitle: Text(switch (settings.frequency) {
              UpdateFrequency.manual => 'Only with Check now below',
              UpdateFrequency.eachStart => 'When the app starts',
              _ => 'When the app starts, and ${settings.frequency.label.toLowerCase()} while it runs',
            }),
            trailing: AppDropdown<UpdateFrequency>(
              value: settings.frequency,
              underline: const SizedBox.shrink(),
              items: [for (final f in UpdateFrequency.values) DropdownMenuItem(value: f, child: Text(f.label))],
              onChanged: (f) => f == null ? null : controller.save(settings.copyWith(frequency: f)),
            ),
          ),
          SwitchListTile(
            title: const Text('Notify me about new versions'),
            subtitle: const Text('A reminder each time the app starts until you update. Off: only shown here'),
            value: settings.notify,
            onChanged: settings.autoCheck ? (v) => controller.save(settings.copyWith(notify: v)) : null,
          ),
        ],
        ListTile(
          leading: const Icon(Icons.system_update_outlined),
          title: const Text('Check for updates'),
          subtitle: Text(subtitle),
          trailing: status.checking
              ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
              : available != null
                  ? FilledButton(onPressed: () => showUpdateDialog(context, available), child: const Text('Update'))
                  : OutlinedButton(
                      onPressed: () => ref.read(updateCheckProvider.notifier).check(),
                      child: const Text('Check now'),
                    ),
          onTap: available != null ? () => showUpdateDialog(context, available) : null,
        ),
      ],
    );
  }
}

/// What's new in [release], and Download and install.
Future<void> showUpdateDialog(BuildContext context, AppRelease release) =>
    showDialog<void>(context: context, builder: (_) => _UpdateDialog(release));

class _UpdateDialog extends ConsumerStatefulWidget {
  const _UpdateDialog(this.release);

  final AppRelease release;

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  /// While downloading: 0–1 (null before the size is known).
  double? _progress;
  bool _busy = false;
  String? _message;

  /// Android: sent to allow installs from the app. Back here, it goes on
  /// by itself (the file is already downloaded).
  bool _awaitingPermission = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _resumed);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _resumed() async {
    if (!_awaitingPermission || _busy) return;
    _awaitingPermission = false;
    if (await ref.read(updateInstallerProvider).canInstall()) {
      await _install();
    } else if (mounted) {
      setState(() => _message = "Installing from this app isn't allowed yet. Press Download and install to open that page again.");
    }
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _progress = null;
      _message = null;
    });
    try {
      final result = await ref.read(updateInstallerProvider).install(
            widget.release,
            onProgress: (p) {
              if (mounted) setState(() => _progress = p);
            },
          );
      if (!mounted) return;
      switch (result) {
        case InstallResult.started:
          if (Platform.isAndroid) Navigator.pop(context);
        case InstallResult.needsPermission:
          _awaitingPermission = true;
          setState(() => _message = 'Allow installing from this app on the page that opened, then come back: '
              'the update goes on by itself.');
        case InstallResult.notWritable:
          setState(() => _message = "The app's folder can't be updated from here (it may be in Program Files). "
              'Download the zip from the release page instead.');
        case InstallResult.noFile:
          setState(() => _message = 'This release has no file for this device. See the release page.');
      }
    } catch (e) {
      if (mounted) setState(() => _message = 'The download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Flexible(child: Text('Version ${r.version}')),
          if (r.isBeta) ...[
            const SizedBox(width: 10),
            Chip(label: const Text('Beta'), visualDensity: VisualDensity.compact),
          ],
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r.publishedAt != null)
              Text('Released ${timeAgo(r.publishedAt!)}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: r.notes.isEmpty
                    ? const Text('No notes for this release.')
                    // Formatted as on GitHub (bold, lists, headings, links).
                    : MarkdownBody(
                        data: r.notes,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                          p: theme.textTheme.bodyMedium,
                          listBullet: theme.textTheme.bodyMedium,
                        ),
                        onTapLink: (_, href, _) {
                          final url = href == null ? null : Uri.tryParse(href);
                          if (url != null) launchUrl(url, mode: LaunchMode.externalApplication);
                        },
                      ),
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 6),
              Text(
                _progress == null
                    ? 'Downloading…'
                    : _progress! >= 1
                        ? Platform.isAndroid
                            ? 'Opening the installer…'
                            : 'Restarting to update…'
                        : 'Downloading… ${(_progress! * 100).round()} %',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => launchUrl(r.page, mode: LaunchMode.externalApplication),
          child: const Text('Release page'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
        FilledButton(
          autofocus: true,
          onPressed: _busy ? null : _install,
          child: Text(Platform.isAndroid ? 'Download and install' : 'Update and restart'),
        ),
      ],
    );
  }
}

/// Checks for updates when the app starts, then as often as Settings says
/// (also on coming back to the app, as a phone keeps it open for days),
/// with a notification for a newer version: once per version each run, so
/// again at every start until it's installed.
class UpdateWatcher {
  UpdateWatcher(this._container, {required this.open, this.onReturn});

  final ProviderContainer _container;

  /// Opens the update dialog (from the notification's Update).
  final void Function(AppRelease release) open;

  static const firstCheck = Duration(seconds: 10);

  /// Back in front: checked again when the last check is older than this
  /// (null: the interval chosen in Settings).
  final Duration? onReturn;

  Timer? _timer;
  bool _started = false;
  AppLifecycleListener? _lifecycle;
  ProviderSubscription<AsyncValue<UpdateSettings>>? _settings;
  final _told = <String>{};

  Duration? get _every => _container.read(updateSettingsProvider).value?.frequency.every;

  void start() {
    _timer = Timer(firstCheck, () {
      _started = true;
      _tick();
    });
    _lifecycle = AppLifecycleListener(onResume: _returned);
    // A new interval applies straight away.
    _settings = _container.listen(updateSettingsProvider, (_, _) => _schedule());
  }

  void _schedule() {
    if (!_started) return;
    _timer?.cancel();
    final every = _every;
    _timer = every == null ? null : Timer(every, _tick);
  }

  void _returned() {
    final last = _container.read(updateCheckProvider).checkedAt;
    final after = onReturn ?? _every;
    // Not before the first check (its timer is still running).
    if (last != null && after != null && DateTime.now().difference(last) >= after) _tick();
  }

  Future<void> _tick() async {
    final settings = await _container.read(updateSettingsProvider.future);
    _schedule();
    if (!settings.autoCheck) return;
    final release = await _container.read(updateCheckProvider.notifier).check();
    if (release == null || !settings.notify || !_told.add(release.tag)) return;
    showToast(
      'Version ${release.version}${release.isBeta ? ' (beta)' : ''} is available',
      actionLabel: 'Update',
      onAction: () => open(release),
      duration: const Duration(seconds: 12),
      id: 'app-update',
    );
  }

  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    _settings?.close();
  }
}
