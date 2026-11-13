import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the player's controls look (item 8).
enum PlayerTheme {
  standard('Default', "The bars as they've always been"),
  minimal('Minimal', 'A thin seek bar and small icons, only while the mouse moves'),
  cinema('Cinema', 'A big play button in the middle, the title large at the top'),
  classic('Classic', 'A solid bar along the bottom with every control in one row'),
  glass('Glass', 'Blurred, see-through panels behind the controls');

  const PlayerTheme(this.label, this.description);

  final String label;
  final String description;
}

enum ControlsSize {
  normal('Normal'),
  large('Large');

  const ControlsSize(this.label);

  final String label;
}

/// What the time next to the seek bar says.
enum TimeDisplay {
  elapsed('Elapsed / total', '5:09 / 26:01'),
  remaining('Time left', '−20:52'),
  endsAt('Ends at', 'Ends at 01:15');

  const TimeDisplay(this.label, this.example);

  final String label;
  final String example;
}

/// What the top bar shows.
enum TitleArea {
  full('Show, episode and chapter'),
  title('Show and episode'),
  hidden('Nothing (just the buttons)');

  const TitleArea(this.label);

  final String label;
}

/// Buttons the bottom bar can show.
enum PlayerButton {
  previousNext('Previous / next'),
  skip10('Back / ahead 10 s'),
  volume('Volume'),
  speed('Speed'),
  tracks('Audio & subtitles'),
  chapters('Chapters'),
  aspect('Aspect ratio'),
  quality('Quality'),
  fullscreen('Fullscreen');

  const PlayerButton(this.label);

  final String label;

  /// Only where they make sense: phones set volume with the keys / swipes.
  bool get onPhones => this != volume;
}

class PlayerLook {
  const PlayerLook({
    this.theme = PlayerTheme.standard,
    ControlsSize? size,
    this.buttons = defaultButtons,
    this.time = TimeDisplay.elapsed,
    this.chapterMarks = true,
    this.trickplay = true,
    this.hideAfterSeconds = 3,
    this.titleArea = TitleArea.full,
  // A named parameter can't be private: this._size isn't possible.
  // ignore: prefer_initializing_formals
  }) : _size = size;

  /// Large on a PC (the controls looked small there), normal elsewhere.
  static ControlsSize get _defaultSize => Platform.isWindows ? ControlsSize.large : ControlsSize.normal;

  static const defaultButtons = {
    PlayerButton.previousNext,
    PlayerButton.volume,
    PlayerButton.tracks,
    PlayerButton.quality,
    PlayerButton.fullscreen,
  };

  final PlayerTheme theme;

  /// The chosen size; unset: [_defaultSize].
  final ControlsSize? _size;
  ControlsSize get size => _size ?? _defaultSize;
  final Set<PlayerButton> buttons;
  final TimeDisplay time;
  final bool chapterMarks;
  final bool trickplay;

  /// How long the controls stay up after the mouse stops (or a tap).
  final int hideAfterSeconds;
  final TitleArea titleArea;

  bool get large => size == ControlsSize.large;

  /// Icon size for the bars' buttons.
  double get iconSize => switch ((theme, large)) {
        (PlayerTheme.minimal, false) => 20,
        (PlayerTheme.minimal, true) => 24,
        (_, false) => 24,
        (_, true) => 30,
      };

  /// Height of a bar.
  double get barHeight => switch ((theme, large)) {
        (PlayerTheme.minimal, _) => large ? 52 : 44,
        (_, false) => 56,
        (_, true) => 72,
      };

  /// Room between the bars and the window's edges.
  double get edgePadding => large ? 20 : 8;

  bool shows(PlayerButton b) => buttons.contains(b);

  PlayerLook copyWith({
    PlayerTheme? theme,
    ControlsSize? size,
    Set<PlayerButton>? buttons,
    TimeDisplay? time,
    bool? chapterMarks,
    bool? trickplay,
    int? hideAfterSeconds,
    TitleArea? titleArea,
  }) =>
      PlayerLook(
        theme: theme ?? this.theme,
        size: size ?? this.size,
        buttons: buttons ?? this.buttons,
        time: time ?? this.time,
        chapterMarks: chapterMarks ?? this.chapterMarks,
        trickplay: trickplay ?? this.trickplay,
        hideAfterSeconds: hideAfterSeconds ?? this.hideAfterSeconds,
        titleArea: titleArea ?? this.titleArea,
      );
}

final playerLookProvider = AsyncNotifierProvider<PlayerLookController, PlayerLook>(PlayerLookController.new);

class PlayerLookController extends AsyncNotifier<PlayerLook> {
  static const _prefix = 'playerLook.';

  static T _parse<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;

  @override
  Future<PlayerLook> build() async {
    final prefs = await SharedPreferences.getInstance();
    const d = PlayerLook();
    final buttons = prefs.getStringList('${_prefix}buttons');
    return PlayerLook(
      theme: _parse(PlayerTheme.values, prefs.getString('${_prefix}theme'), d.theme),
      size: _parse(ControlsSize.values, prefs.getString('${_prefix}size'), d.size),
      buttons: buttons == null
          ? d.buttons
          : {
              for (final b in PlayerButton.values) if (buttons.contains(b.name)) b,
              // Added after these were saved: shown until it's turned off.
              if (prefs.getBool('${_prefix}qualityOffered') == null) PlayerButton.quality,
            },
      time: _parse(TimeDisplay.values, prefs.getString('${_prefix}time'), d.time),
      chapterMarks: prefs.getBool('${_prefix}chapterMarks') ?? d.chapterMarks,
      trickplay: prefs.getBool('${_prefix}trickplay') ?? d.trickplay,
      hideAfterSeconds: prefs.getInt('${_prefix}hideAfterSeconds') ?? d.hideAfterSeconds,
      titleArea: _parse(TitleArea.values, prefs.getString('${_prefix}titleArea'), d.titleArea),
    );
  }

  Future<void> save(PlayerLook look) async {
    await future.catchError((Object _) => const PlayerLook());
    state = AsyncData(look);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}theme', look.theme.name);
    await prefs.setString('${_prefix}size', look.size.name);
    await prefs.setStringList('${_prefix}buttons', [for (final b in look.buttons) b.name]);
    await prefs.setBool('${_prefix}qualityOffered', true);
    await prefs.setString('${_prefix}time', look.time.name);
    await prefs.setBool('${_prefix}chapterMarks', look.chapterMarks);
    await prefs.setBool('${_prefix}trickplay', look.trickplay);
    await prefs.setInt('${_prefix}hideAfterSeconds', look.hideAfterSeconds);
    await prefs.setString('${_prefix}titleArea', look.titleArea.name);
  }
}
