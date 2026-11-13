import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../app/toast.dart';
import '../../settings/playback_settings.dart' show StreamQuality;
import '../media_engine.dart';
import '../media_kit_engine.dart';
import '../player_look.dart';

const _shadows = [Shadow(blurRadius: 6, color: Colors.black87)];

String formatTime(Duration d) {
  final h = d.inHours;
  final m = (d.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// The time beside the seek bar: elapsed / total, time left, or when it'll
/// end (Settings > Player controls > Time).
class PlayerTimeLabel extends StatelessWidget {
  const PlayerTimeLabel({super.key, required this.player, required this.display, this.fontSize = 14});

  final Player player;
  final TimeDisplay display;
  final double fontSize;

  /// The text for [position] of [duration] (also for tests).
  static String text(TimeDisplay display, Duration position, Duration duration, {DateTime? now, double rate = 1}) {
    final left = duration - position;
    return switch (display) {
      TimeDisplay.elapsed => '${formatTime(position)} / ${formatTime(duration)}',
      TimeDisplay.remaining => '−${formatTime(left.isNegative ? Duration.zero : left)}',
      TimeDisplay.endsAt => () {
          final end = (now ?? DateTime.now()).add(left * (1 / (rate <= 0 ? 1 : rate)));
          return 'Ends at ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
        }(),
    };
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (context, snapshot) => Text(
          text(display, snapshot.data ?? Duration.zero, player.state.duration, rate: player.state.rate),
          style: TextStyle(color: Colors.white, fontSize: fontSize, shadows: _shadows, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      );
}

/// A bar button that opens a short list (speed, chapters, aspect) above it.
class _ListButton<T> extends StatelessWidget {
  const _ListButton({
    required this.tooltip,
    required this.icon,
    required this.iconSize,
    required this.items,
    required this.selected,
    required this.onSelected,
  });

  final String tooltip;
  final IconData icon;
  final double iconSize;
  final List<(T, String)> Function() items;
  final T? Function() selected;
  final ValueChanged<T> onSelected;

  /// Opens the list above the button. The pick is passed on even when the
  /// bar has faded out (taking this button with it) while the list was
  /// open, which a [PopupMenuButton] would drop.
  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final now = selected();
    final picked = await showMenu<T>(
      context: context,
      position: position,
      items: [
        for (final (value, label) in items())
          CheckedPopupMenuItem<T>(value: value, checked: value == now, child: Text(label)),
      ],
    );
    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) => Builder(
        builder: (context) => IconButton(
          tooltip: tooltip,
          color: Colors.white,
          iconSize: iconSize,
          icon: Icon(icon, shadows: _shadows),
          onPressed: () => _open(context),
        ),
      );
}

const playbackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
const aspectModes = [('auto', 'Auto'), ('16:9', '16:9'), ('4:3', '4:3'), ('fill', 'Fill (crop)'), ('stretch', 'Stretch')];

/// The picture's shape as last chosen (mpv keeps it per player).
String currentAspect = 'auto';

String rateLabel(double r) => r == 1 ? 'Normal' : '${r}x';

Widget speedButton(Player player, double iconSize) => _ListButton<double>(
      tooltip: 'Speed',
      icon: Icons.speed,
      iconSize: iconSize,
      items: () => [for (final r in playbackRates) (r, rateLabel(r))],
      selected: () => player.state.rate,
      onSelected: player.setRate,
    );

/// Streaming quality: Auto, Original, or a limit. Under Auto, once it has
/// stepped down, its line says to what.
Widget qualityButton({
  required StreamQuality Function() current,
  required String Function() autoLabel,
  required ValueChanged<StreamQuality> onSelected,
  required double iconSize,
}) =>
    _ListButton<StreamQuality>(
      tooltip: 'Quality',
      icon: Icons.high_quality_outlined,
      iconSize: iconSize,
      items: () => [
        for (final q in StreamQuality.values) (q, q == StreamQuality.auto ? autoLabel() : q.label),
      ],
      selected: current,
      onSelected: onSelected,
    );

Widget aspectButton(MediaKitEngine engine, double iconSize) => _ListButton<String>(
      tooltip: 'Aspect ratio',
      icon: Icons.aspect_ratio,
      iconSize: iconSize,
      items: () => aspectModes,
      selected: () => currentAspect,
      onSelected: (mode) async {
        currentAspect = mode;
        await engine.setAspect(mode);
      },
    );

Widget chaptersButton({
  required List<Chapter> Function() chapters,
  required String Function(int index) label,
  required int? Function() current,
  required ValueChanged<Duration> seek,
  required double iconSize,
}) =>
    _ListButton<int>(
      tooltip: 'Chapters',
      icon: Icons.format_list_numbered,
      iconSize: iconSize,
      items: () => [
        for (final (i, c) in chapters().indexed) (i, '${formatTime(c.start)}  ${label(i)}'),
      ],
      selected: current,
      onSelected: (i) => seek(chapters()[i].start),
    );

/// Classic and Glass: a panel behind the bottom bar's controls.
class PlayerBarPanel extends StatelessWidget {
  const PlayerBarPanel({super.key, required this.theme, required this.child});

  final PlayerTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final row = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: child);
    return switch (theme) {
      PlayerTheme.classic => DecoratedBox(
          decoration: const BoxDecoration(color: Color(0xE6101114)),
          child: row,
        ),
      PlayerTheme.glass => ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                borderRadius: BorderRadius.circular(18),
              ),
              child: row,
            ),
          ),
        ),
      _ => child,
    };
  }
}

/// What the right-click menu needs from the player (Windows).
class PlayerMenuActions {
  const PlayerMenuActions({
    required this.engine,
    required this.chapters,
    required this.chapterLabel,
    required this.currentChapter,
    required this.seek,
    required this.watchTogether,
    required this.miniPlayer,
    required this.playbackInfo,
    required this.position,
    this.onAudioChosen,
    this.onSubtitleChosen,
    this.moreTracks,
    this.quality,
    this.qualityAutoLabel,
    this.onQuality,
    this.burnable,
    this.burnedIn,
    this.onBurnIn,
  });

  final MediaKitEngine engine;
  final List<Chapter> Function() chapters;
  final String Function(int index) chapterLabel;
  final int? Function() currentChapter;
  final ValueChanged<Duration> seek;
  final VoidCallback watchTogether;
  final VoidCallback? miniPlayer;
  final VoidCallback playbackInfo;
  final Duration Function() position;
  final void Function(AudioTrack track)? onAudioChosen;
  final void Function(SubtitleTrack? track)? onSubtitleChosen;

  /// The full audio & subtitles sheet (delays and all).
  final VoidCallback? moreTracks;

  /// Streaming quality: what's picked, Auto's line, and picking one.
  final StreamQuality Function()? quality;
  final String Function()? qualityAutoLabel;
  final ValueChanged<StreamQuality>? onQuality;

  /// Picture subtitles a converted stream can have burned in (stream index,
  /// label), the one that is, and asking for one (null: none).
  final List<(int, String)> Function()? burnable;
  final int? Function()? burnedIn;
  final ValueChanged<int?>? onBurnIn;
}

String trackLabel(String? title, String? language, String? codec, String id) {
  final parts = [
    if (title != null && title.isNotEmpty) title,
    if (language != null && language.isNotEmpty) language.toUpperCase(),
    if (codec != null && codec.isNotEmpty) codec.toUpperCase(),
  ];
  return parts.isEmpty ? 'Track $id' : parts.join(' · ');
}

/// Right-click on the video (Windows): audio, subtitles, chapters, speed,
/// aspect ratio, and the player's other actions, in a menu at the mouse.
class PlayerContextMenuArea extends StatefulWidget {
  const PlayerContextMenuArea({super.key, required this.actions, required this.child});

  final PlayerMenuActions actions;
  final Widget child;

  @override
  State<PlayerContextMenuArea> createState() => _PlayerContextMenuAreaState();
}

class _PlayerContextMenuAreaState extends State<PlayerContextMenuArea> {
  final _menu = MenuController();

  /// Open: a see-through layer over the video takes the next click (it
  /// closes the menu, and doesn't also pause or play) and Esc.
  bool _isOpen = false;

  Player get _player => widget.actions.engine.player;

  void _open(Offset at) {
    // Built afresh for what's playing now, then opened at the mouse (a
    // right-click while it's open moves it there).
    _menu.close();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menu.open(position: at);
    });
  }

  void _close() => _menu.close();

  Widget _check(bool on) => SizedBox(width: 24, child: on ? const Icon(Icons.check, size: 18) : null);

  List<Widget> _items() {
    final a = widget.actions;
    final tracks = _player.state.tracks;
    final current = _player.state.track;
    final audio = [for (final t in tracks.audio) if (t.id != 'auto' && t.id != 'no') t];
    final subs = [for (final t in tracks.subtitle) if (t.id != 'auto' && t.id != 'no') t];
    final chapters = a.chapters();
    final chapterNow = a.currentChapter();
    final burned = a.burnedIn?.call();
    return [
      SubmenuButton(
        leadingIcon: const Icon(Icons.audiotrack_outlined),
        menuChildren: [
          if (audio.isEmpty) const MenuItemButton(child: Text('No audio tracks')),
          for (final t in audio)
            MenuItemButton(
              leadingIcon: _check(t.id == current.audio.id),
              onPressed: () async {
                await _player.setAudioTrack(t);
                a.onAudioChosen?.call(t);
              },
              child: Text(trackLabel(t.title, t.language, t.codec, t.id)),
            ),
        ],
        child: const Text('Audio'),
      ),
      SubmenuButton(
        leadingIcon: const Icon(Icons.subtitles_outlined),
        menuChildren: [
          MenuItemButton(
            leadingIcon: _check(burned == null && current.subtitle.id == 'no'),
            onPressed: () async {
              if (burned != null) a.onBurnIn?.call(null);
              await _player.setSubtitleTrack(SubtitleTrack.no());
              a.onSubtitleChosen?.call(null);
            },
            child: const Text('Off'),
          ),
          for (final t in subs)
            MenuItemButton(
              leadingIcon: _check(burned == null && t.id == current.subtitle.id),
              onPressed: () async {
                a.onSubtitleChosen?.call(t);
                // Back from burned in: the stream restarts and picks by language.
                if (burned != null) return a.onBurnIn?.call(null);
                await _player.setSubtitleTrack(t);
              },
              child: Text(trackLabel(t.title, t.language, t.codec, t.id)),
            ),
          for (final (index, label) in a.burnable?.call() ?? const <(int, String)>[])
            MenuItemButton(
              leadingIcon: _check(burned == index),
              onPressed: () => a.onBurnIn?.call(index),
              child: Text('$label (burned in)'),
            ),
          if (a.moreTracks != null) ...[
            const Divider(height: 8),
            MenuItemButton(onPressed: a.moreTracks, child: const Text('Delay and more…')),
          ],
        ],
        child: const Text('Subtitles'),
      ),
      if (chapters.isNotEmpty)
        SubmenuButton(
          leadingIcon: const Icon(Icons.format_list_numbered),
          menuChildren: [
            for (final (i, c) in chapters.indexed)
              MenuItemButton(
                leadingIcon: _check(i == chapterNow),
                trailingIcon: Text(formatTime(c.start)),
                onPressed: () => a.seek(c.start),
                child: Text(a.chapterLabel(i)),
              ),
          ],
          child: const Text('Chapters'),
        ),
      SubmenuButton(
        leadingIcon: const Icon(Icons.speed),
        menuChildren: [
          for (final r in playbackRates)
            MenuItemButton(
              leadingIcon: _check(_player.state.rate == r),
              onPressed: () => _player.setRate(r),
              child: Text(rateLabel(r)),
            ),
        ],
        child: const Text('Speed'),
      ),
      if (a.quality != null && a.onQuality != null)
        SubmenuButton(
          leadingIcon: const Icon(Icons.high_quality_outlined),
          menuChildren: [
            for (final q in StreamQuality.values)
              MenuItemButton(
                leadingIcon: _check(a.quality!() == q),
                onPressed: () => a.onQuality!(q),
                child: Text(q == StreamQuality.auto ? (a.qualityAutoLabel?.call() ?? q.label) : q.label),
              ),
          ],
          child: const Text('Quality'),
        ),
      SubmenuButton(
        leadingIcon: const Icon(Icons.aspect_ratio),
        menuChildren: [
          for (final (mode, label) in aspectModes)
            MenuItemButton(
              leadingIcon: _check(currentAspect == mode),
              onPressed: () async {
                currentAspect = mode;
                await a.engine.setAspect(mode);
              },
              child: Text(label),
            ),
        ],
        child: const Text('Aspect ratio'),
      ),
      const Divider(height: 8),
      MenuItemButton(leadingIcon: const Icon(Icons.groups_outlined), onPressed: a.watchTogether, child: const Text('Watch together')),
      if (a.miniPlayer != null && !isFullscreen(context))
        MenuItemButton(
          leadingIcon: const Icon(Icons.picture_in_picture_alt_outlined),
          onPressed: a.miniPlayer,
          child: const Text('Mini player'),
        ),
      MenuItemButton(leadingIcon: const Icon(Icons.info_outline), onPressed: a.playbackInfo, child: const Text('Playback info')),
      MenuItemButton(
        leadingIcon: const Icon(Icons.copy),
        onPressed: () {
          final at = formatTime(a.position());
          Clipboard.setData(ClipboardData(text: at));
          showToast('Copied $at');
        },
        child: const Text('Copy timestamp'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
        controller: _menu,
        menuChildren: _items(),
        onOpen: () => setState(() => _isOpen = true),
        onClose: () {
          if (mounted) setState(() => _isOpen = false);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onSecondaryTapUp: (d) => _open(d.localPosition),
              child: widget.child,
            ),
            // The video is the menu's anchor, so a click on it didn't count
            // as "outside" and the menu stayed open: this layer closes it.
            if (_isOpen)
              Positioned.fill(
                child: Focus(
                  autofocus: true,
                  onKeyEvent: (_, event) {
                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                      _close();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (_) => _close(),
                    onSecondaryTapUp: (d) => _open(d.localPosition),
                  ),
                ),
              ),
          ],
        ),
      );
}
