import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player_look.dart';
import 'player_controls.dart';
import '../../../app/app_dropdown.dart';

/// Settings > Player controls > Player layout: theme (with a preview), size,
/// buttons, time, seek bar, how long the controls stay, the title area.
/// Only what applies on the device is shown.
class PlayerLookSection extends ConsumerWidget {
  const PlayerLookSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(playerLookProvider).value ?? const PlayerLook();
    final controller = ref.read(playerLookProvider.notifier);
    final phone = Platform.isAndroid;
    Future<void> save(PlayerLook l) => controller.save(l);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: PlayerLookPreview(look: look),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Changes apply to the next video you open.', style: TextStyle(fontSize: 12)),
        ),
        ListTile(
          title: const Text('Player theme'),
          subtitle: Text(look.theme.description),
          trailing: AppDropdown<PlayerTheme>(
            value: look.theme,
            underline: const SizedBox.shrink(),
            items: [for (final t in PlayerTheme.values) DropdownMenuItem(value: t, child: Text(t.label))],
            onChanged: (t) => t == null ? null : save(look.copyWith(theme: t)),
          ),
        ),
        ListTile(
          title: const Text('Controls size'),
          trailing: SegmentedButton<ControlsSize>(
            showSelectedIcon: false,
            segments: [for (final s in ControlsSize.values) ButtonSegment(value: s, label: Text(s.label))],
            selected: {look.size},
            onSelectionChanged: (s) => save(look.copyWith(size: s.first)),
          ),
        ),
        ListTile(
          title: const Text('Buttons'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final b in PlayerButton.values)
                  if (!phone || b.onPhones)
                    FilterChip(
                      label: Text(b.label),
                      selected: look.shows(b),
                      onSelected: (on) => save(look.copyWith(buttons: on ? {...look.buttons, b} : ({...look.buttons}..remove(b)))),
                    ),
              ],
            ),
          ),
        ),
        ListTile(
          title: const Text('Time'),
          subtitle: Text(look.time.example),
          trailing: AppDropdown<TimeDisplay>(
            value: look.time,
            underline: const SizedBox.shrink(),
            items: [for (final t in TimeDisplay.values) DropdownMenuItem(value: t, child: Text(t.label))],
            onChanged: (t) => t == null ? null : save(look.copyWith(time: t)),
          ),
        ),
        SwitchListTile(
          title: const Text('Chapter marks on the seek bar'),
          value: look.chapterMarks,
          onChanged: (v) => save(look.copyWith(chapterMarks: v)),
        ),
        SwitchListTile(
          title: const Text('Thumbnails while seeking'),
          subtitle: const Text("When the server has made them (Jellyfin's trickplay)"),
          value: look.trickplay,
          onChanged: (v) => save(look.copyWith(trickplay: v)),
        ),
        ListTile(
          title: const Text('Hide the controls after'),
          subtitle: Slider(
            value: look.hideAfterSeconds.toDouble(),
            min: 2,
            max: 10,
            divisions: 8,
            label: '${look.hideAfterSeconds} s',
            onChanged: (v) => save(look.copyWith(hideAfterSeconds: v.round())),
          ),
          trailing: Text('${look.hideAfterSeconds} s'),
        ),
        ListTile(
          title: const Text('Top bar'),
          trailing: AppDropdown<TitleArea>(
            value: look.titleArea,
            underline: const SizedBox.shrink(),
            items: [for (final t in TitleArea.values) DropdownMenuItem(value: t, child: Text(t.label))],
            onChanged: (t) => t == null ? null : save(look.copyWith(titleArea: t)),
          ),
        ),
      ],
    );
  }
}

/// A small player in the chosen theme: a picture, the top bar and the
/// bottom bar as they'll look.
class PlayerLookPreview extends StatelessWidget {
  const PlayerLookPreview({super.key, required this.look});

  final PlayerLook look;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final scale = look.large ? 1.2 : 1.0;
    final icon = (look.theme == PlayerTheme.minimal ? 14.0 : 17.0) * scale;
    const white = Colors.white;
    Widget i(IconData d) => Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: Icon(d, size: icon, color: white));
    // The real bar's buttons, in its order, with each theme's rules (see
    // _themedVideo in player_screen.dart).
    final minimal = look.theme == PlayerTheme.minimal;
    final prevNext = look.shows(PlayerButton.previousNext) && !minimal;
    final skips = look.shows(PlayerButton.skip10) && !minimal;
    final bar = Row(
      children: [
        if (prevNext) i(Icons.skip_previous),
        if (skips) i(Icons.replay_10),
        if (look.theme != PlayerTheme.cinema) i(Icons.play_arrow),
        if (skips) i(Icons.forward_10),
        if (prevNext) i(Icons.skip_next),
        if (look.shows(PlayerButton.volume) && !minimal) i(Icons.volume_up),
        const SizedBox(width: 6),
        Text(
          PlayerTimeLabel.text(look.time, const Duration(minutes: 5, seconds: 9), const Duration(minutes: 26, seconds: 1),
              now: DateTime(2026, 1, 1, 0, 54)),
          style: TextStyle(color: white, fontSize: 10 * scale),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Container(height: minimal ? 2 : 3, color: Colors.white24),
              FractionallySizedBox(widthFactor: 0.2, child: Container(height: minimal ? 2 : 3, color: accent)),
              if (look.chapterMarks)
                for (final x in const [0.08, 0.45, 0.9])
                  Align(alignment: Alignment(x * 2 - 1, 0), child: Container(width: 2, height: 7, color: Colors.white70)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (!minimal) ...[
          if (look.shows(PlayerButton.speed)) i(Icons.speed),
          if (look.shows(PlayerButton.chapters)) i(Icons.format_list_numbered),
          if (look.shows(PlayerButton.aspect)) i(Icons.aspect_ratio),
        ],
        if (look.shows(PlayerButton.tracks)) i(Icons.subtitles_outlined),
        if (look.shows(PlayerButton.quality)) i(Icons.high_quality_outlined),
        if (look.shows(PlayerButton.fullscreen)) i(Icons.fullscreen),
      ],
    );
    final bottom = switch (look.theme) {
      PlayerTheme.classic || PlayerTheme.glass => PlayerBarPanel(
          theme: look.theme,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: bar),
        ),
      _ => bar,
    };
    // At most about a small player's size, centred (it filled a wide pane).
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Stand-in picture.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF2E5E4E), Color(0xFF8DB86B), Color(0xFF233B52)],
                ),
              ),
            ),
            if (look.theme != PlayerTheme.classic)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, 0.3, 0.7, 1],
                    colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black54],
                  ),
                ),
              ),
            if (look.titleArea != TitleArea.hidden)
              Positioned(
                left: 12,
                top: 8,
                right: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Frieren · S1:E1',
                      style: TextStyle(
                        color: white,
                        fontWeight: FontWeight.bold,
                        fontSize: (look.theme == PlayerTheme.cinema ? 16 : 12) * scale,
                      ),
                    ),
                    if (look.titleArea == TitleArea.full)
                      Text('Chapter 02', style: TextStyle(color: Colors.white70, fontSize: 9 * scale)),
                  ],
                ),
              ),
            if (look.theme == PlayerTheme.cinema)
              Center(child: Icon(Icons.play_circle_fill, size: 44 * scale, color: white)),
            Positioned(
              left: look.theme == PlayerTheme.glass ? 12 : 0,
              right: look.theme == PlayerTheme.glass ? 12 : 0,
              bottom: look.theme == PlayerTheme.glass ? 8 : (look.theme == PlayerTheme.classic ? 0 : 6),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: look.theme == PlayerTheme.classic || look.theme == PlayerTheme.glass ? 0 : 10),
                child: bottom,
              ),
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }
}
