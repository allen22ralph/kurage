import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../media_kit_engine.dart';

/// Audio/subtitle track picker plus sync and speed controls.
/// [onAudioChosen] / [onSubtitleChosen] report the user's picks (language,
/// or null subtitle for "off"), so they can be remembered per show.
Future<void> showTrackMenu(
  BuildContext context,
  MediaKitEngine engine, {
  void Function(AudioTrack track)? onAudioChosen,
  void Function(SubtitleTrack? track)? onSubtitleChosen,
  List<(int, String)> burnable = const [],
  int? burnedIn,
  ValueChanged<int?>? onBurnIn,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Dragged closed by touch; with a mouse, dragging slid it about.
    showDragHandle: _touch,
    enableDrag: _touch,
    builder: (context) => _TrackMenu(
      engine: engine,
      onAudioChosen: onAudioChosen,
      onSubtitleChosen: onSubtitleChosen,
      burnable: burnable,
      burnedIn: burnedIn,
      onBurnIn: onBurnIn,
    ),
  );
}

class _TrackMenu extends StatefulWidget {
  const _TrackMenu({
    required this.engine,
    this.onAudioChosen,
    this.onSubtitleChosen,
    this.burnable = const [],
    this.burnedIn,
    this.onBurnIn,
  });

  final MediaKitEngine engine;
  final void Function(AudioTrack track)? onAudioChosen;
  final void Function(SubtitleTrack? track)? onSubtitleChosen;

  /// Picture subtitles a converted stream can have drawn into it (stream
  /// index, label), the one that is, and asking for one (null: none).
  final List<(int, String)> burnable;
  final int? burnedIn;
  final ValueChanged<int?>? onBurnIn;

  @override
  State<_TrackMenu> createState() => _TrackMenuState();
}

class _TrackMenuState extends State<_TrackMenu> {
  // mpv keeps these per player; the menu only remembers them while open.
  static Duration _subtitleDelay = Duration.zero;
  static Duration _audioDelay = Duration.zero;

  /// The picture's shape (see MediaKitEngine.setAspect); "auto" is the
  /// file's (or Jellyfin's, when the file's is off).
  static String _aspect = 'auto';

  Player get _player => widget.engine.player;

  /// What mpv is really playing, for when the last choice was 'auto'.
  ({String? audio, String subtitle})? _playing;

  @override
  void initState() {
    super.initState();
    widget.engine.playingTrackIds().then((ids) {
      if (mounted) setState(() => _playing = ids);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _player.state.tracks;
    final current = _player.state.track;
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _header(theme, 'Audio'),
          RadioGroup<String>(
            groupValue: _isReal(current.audio.id) ? current.audio.id : _playing?.audio,
            onChanged: (id) async {
              final track = tracks.audio.firstWhere((t) => t.id == id);
              await _player.setAudioTrack(track);
              widget.onAudioChosen?.call(track);
              setState(() {});
            },
            child: Column(
              children: [
                for (final track in tracks.audio.where((t) => _isReal(t.id)))
                  RadioListTile<String>(
                    value: track.id,
                    title: Text(_label(track.title, track.language, track.codec, track.id)),
                    subtitle: _channels(track),
                  ),
              ],
            ),
          ),
          _header(theme, 'Subtitles'),
          RadioGroup<String>(
            groupValue: widget.burnedIn != null
                ? 'burn:${widget.burnedIn}'
                : current.subtitle.id == 'auto'
                    ? _playing?.subtitle
                    : current.subtitle.id,
            onChanged: (id) async {
              if (id == null) return;
              // Burning one in restarts the stream: the sheet's done.
              if (id.startsWith('burn:')) {
                Navigator.pop(context);
                widget.onBurnIn?.call(int.parse(id.substring(5)));
                return;
              }
              if (widget.burnedIn != null) {
                Navigator.pop(context);
                widget.onSubtitleChosen?.call(id == 'no' ? null : tracks.subtitle.firstWhere((t) => t.id == id));
                widget.onBurnIn?.call(null);
                return;
              }
              final track = id == 'no' ? null : tracks.subtitle.firstWhere((t) => t.id == id);
              await _player.setSubtitleTrack(track ?? SubtitleTrack.no());
              widget.onSubtitleChosen?.call(track);
              setState(() {});
            },
            child: Column(
              children: [
                const RadioListTile<String>(value: 'no', title: Text('Off')),
                for (final track in tracks.subtitle.where((t) => _isReal(t.id)))
                  RadioListTile<String>(
                    value: track.id,
                    title: Text(_label(track.title, track.language, track.codec, track.id)),
                  ),
                for (final (index, label) in widget.burnable)
                  RadioListTile<String>(
                    value: 'burn:$index',
                    title: Text('$label (burned in)'),
                    subtitle: const Text('A picture subtitle: drawn into the video, the stream restarts'),
                  ),
              ],
            ),
          ),
          _header(theme, 'Sync'),
          _DelayRow(
            label: 'Subtitle delay',
            value: _subtitleDelay,
            onChanged: (d) {
              setState(() => _subtitleDelay = d);
              widget.engine.setSubtitleDelay(d);
            },
          ),
          _DelayRow(
            label: 'Audio delay',
            value: _audioDelay,
            onChanged: (d) {
              setState(() => _audioDelay = d);
              widget.engine.setAudioDelay(d);
            },
          ),
          _header(theme, 'Speed'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final rate in const [0.75, 1.0, 1.25, 1.5, 2.0])
                  ChoiceChip(
                    label: Text('${rate}x'),
                    selected: _player.state.rate == rate,
                    onSelected: (_) async {
                      await _player.setRate(rate);
                      setState(() {});
                    },
                  ),
              ],
            ),
          ),
          _header(theme, 'Aspect ratio'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (mode, label) in const [
                  ('auto', 'Auto'),
                  ('16:9', '16:9'),
                  ('4:3', '4:3'),
                  ('fill', 'Fill (crop)'),
                  ('stretch', 'Stretch'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _aspect == mode,
                    onSelected: (_) async {
                      await widget.engine.setAspect(mode);
                      setState(() => _aspect = mode);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// mpv lists pseudo-tracks "auto" and "no" alongside the real ones.
  static bool _isReal(String id) => id != 'auto' && id != 'no';

  Widget _header(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: theme.textTheme.titleMedium),
  );

  Widget? _channels(AudioTrack track) {
    final channels = track.audiochannels ?? track.channelscount;
    return channels == null ? null : Text('$channels ch');
  }

  static String _label(String? title, String? language, String? codec, String id) {
    final parts = [
      if (title != null && title.isNotEmpty) title,
      if (language != null && language.isNotEmpty) language.toUpperCase(),
      if (codec != null && codec.isNotEmpty) codec.toUpperCase(),
    ];
    return parts.isEmpty ? 'Track $id' : parts.join(' · ');
  }
}

class _DelayRow extends StatelessWidget {
  const _DelayRow({required this.label, required this.value, required this.onChanged});

  final String label;
  final Duration value;
  final ValueChanged<Duration> onChanged;

  static const _step = Duration(milliseconds: 100);

  @override
  Widget build(BuildContext context) {
    final seconds = value.inMilliseconds / 1000;
    return ListTile(
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(tooltip: '-0.1s', icon: const Icon(Icons.remove), onPressed: () => onChanged(value - _step)),
          SizedBox(
            width: 64,
            child: Text('${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(1)}s', textAlign: TextAlign.center),
          ),
          IconButton(tooltip: '+0.1s', icon: const Icon(Icons.add), onPressed: () => onChanged(value + _step)),
          IconButton(tooltip: 'Reset', icon: const Icon(Icons.restart_alt), onPressed: () => onChanged(Duration.zero)),
        ],
      ),
    );
  }
}

bool get _touch => Platform.isAndroid || Platform.isIOS;
