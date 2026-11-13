import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Something a key can do in the player.
enum PlayerAction {
  playPause('Play / pause'),
  seekBack10('Back 10 seconds'),
  seekForward10('Forward 10 seconds'),
  seekBackSmall('Back 2 seconds'),
  seekForwardSmall('Forward 2 seconds'),
  volumeUp('Volume up'),
  volumeDown('Volume down'),
  toggleFullscreen('Fullscreen'),
  exitFullscreen('Exit fullscreen'),
  skipSegment('Skip intro / recap / credits'),
  nextEpisode('Next episode'),
  previousEpisode('Previous episode'),
  nextChapter('Next chapter (then next episode)'),
  previousChapter('Previous chapter (then previous episode)'),
  playbackInfo('Playback info'),
  miniPlayer('Mini player (picture-in-picture)'),
  // On Home (outside the player); kept with the others so it can be
  // changed the same way.
  refreshHome('Refresh Home');

  const PlayerAction(this.label);

  final String label;
}

/// Which keys trigger which [PlayerAction]. A key belongs to one action.
class Keybindings {
  const Keybindings(this._keys);

  /// media_kit's own desktop defaults, plus our player keys (S, N, P, I)
  /// and mpv's chapter keys (Page Up / Page Down).
  /// media_kit binds I to "+10s"; that moves to L (as on YouTube) so I can
  /// open playback info.
  static final defaults = Keybindings({
    PlayerAction.playPause: const [
      SingleActivator(LogicalKeyboardKey.space),
      SingleActivator(LogicalKeyboardKey.mediaPlayPause),
    ],
    PlayerAction.seekBack10: const [SingleActivator(LogicalKeyboardKey.keyJ)],
    PlayerAction.seekForward10: const [SingleActivator(LogicalKeyboardKey.keyL)],
    PlayerAction.seekBackSmall: const [SingleActivator(LogicalKeyboardKey.arrowLeft)],
    PlayerAction.seekForwardSmall: const [SingleActivator(LogicalKeyboardKey.arrowRight)],
    PlayerAction.volumeUp: const [SingleActivator(LogicalKeyboardKey.arrowUp)],
    PlayerAction.volumeDown: const [SingleActivator(LogicalKeyboardKey.arrowDown)],
    PlayerAction.toggleFullscreen: const [SingleActivator(LogicalKeyboardKey.keyF)],
    PlayerAction.exitFullscreen: const [SingleActivator(LogicalKeyboardKey.escape)],
    PlayerAction.skipSegment: const [SingleActivator(LogicalKeyboardKey.keyS)],
    PlayerAction.nextEpisode: const [
      SingleActivator(LogicalKeyboardKey.keyN),
      SingleActivator(LogicalKeyboardKey.mediaTrackNext),
    ],
    PlayerAction.previousEpisode: const [
      SingleActivator(LogicalKeyboardKey.keyP),
      SingleActivator(LogicalKeyboardKey.mediaTrackPrevious),
    ],
    PlayerAction.nextChapter: const [SingleActivator(LogicalKeyboardKey.pageDown)],
    PlayerAction.previousChapter: const [SingleActivator(LogicalKeyboardKey.pageUp)],
    PlayerAction.playbackInfo: const [SingleActivator(LogicalKeyboardKey.keyI)],
    PlayerAction.miniPlayer: const [SingleActivator(LogicalKeyboardKey.keyM)],
    PlayerAction.refreshHome: const [
      SingleActivator(LogicalKeyboardKey.f5),
      SingleActivator(LogicalKeyboardKey.keyR, control: true),
    ],
  });

  final Map<PlayerAction, List<SingleActivator>> _keys;

  List<SingleActivator> keysFor(PlayerAction action) => _keys[action] ?? const [];

  Iterable<MapEntry<PlayerAction, List<SingleActivator>>> get entries => _keys.entries;

  PlayerAction? actionFor(SingleActivator key) {
    for (final MapEntry(key: action, value: keys) in _keys.entries) {
      if (keys.any((k) => sameKey(k, key))) return action;
    }
    return null;
  }

  /// Adds [key] to [action], taking it off whichever action had it.
  /// Returns the new bindings and that other action, if any.
  (Keybindings, PlayerAction?) bind(PlayerAction action, SingleActivator key) {
    final previous = actionFor(key);
    if (previous == action) return (this, null);
    final keys = {
      for (final MapEntry(key: a, value: list) in _keys.entries)
        a: [...list.where((k) => !sameKey(k, key))],
    };
    keys[action] = [...?keys[action], key];
    return (Keybindings(keys), previous);
  }

  Keybindings unbind(PlayerAction action, SingleActivator key) => Keybindings({
        ..._keys,
        action: [...keysFor(action).where((k) => !sameKey(k, key))],
      });

  Map<String, Object?> toJson() => {
        for (final MapEntry(key: action, value: keys) in _keys.entries)
          action.name: [for (final k in keys) _keyToJson(k)],
      };

  /// Unknown actions are dropped; actions missing from [json] (e.g. added in
  /// a later version) keep their defaults.
  factory Keybindings.fromJson(Map<String, Object?> json) {
    final keys = {...defaults._keys};
    for (final action in PlayerAction.values) {
      final list = json[action.name];
      if (list is List) {
        keys[action] = [
          for (final k in list)
            if (k is Map<String, Object?>) _keyFromJson(k),
        ];
      }
    }
    return Keybindings(keys);
  }

  static Map<String, Object?> _keyToJson(SingleActivator k) => {
        'key': k.trigger.keyId,
        if (k.control) 'ctrl': true,
        if (k.shift) 'shift': true,
        if (k.alt) 'alt': true,
        if (k.meta) 'meta': true,
      };

  static SingleActivator _keyFromJson(Map<String, Object?> j) {
    final id = j['key'] as int;
    return SingleActivator(
      LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id),
      control: j['ctrl'] == true,
      shift: j['shift'] == true,
      alt: j['alt'] == true,
      meta: j['meta'] == true,
    );
  }
}

/// SingleActivator has no value equality.
bool sameKey(SingleActivator a, SingleActivator b) =>
    a.trigger == b.trigger &&
    a.control == b.control &&
    a.shift == b.shift &&
    a.alt == b.alt &&
    a.meta == b.meta;

/// "Ctrl+Shift+F", "Space", "Arrow Left"…
String describeKey(SingleActivator k) {
  final label = k.trigger == LogicalKeyboardKey.space
      ? 'Space'
      : k.trigger.keyLabel.trim().isEmpty
          ? (k.trigger.debugName ?? 'Key ${k.trigger.keyId}')
          : k.trigger.keyLabel;
  return [
    if (k.control) 'Ctrl',
    if (k.alt) 'Alt',
    if (k.shift) 'Shift',
    if (k.meta) 'Win',
    label,
  ].join('+');
}

final keybindingsProvider =
    AsyncNotifierProvider<KeybindingsController, Keybindings>(KeybindingsController.new);

class KeybindingsController extends AsyncNotifier<Keybindings> {
  static const _key = 'player.keybindings';

  @override
  Future<Keybindings> build() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return Keybindings.defaults;
    try {
      return Keybindings.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on FormatException {
      return Keybindings.defaults;
    }
  }

  Future<void> save(Keybindings bindings) async {
    state = AsyncData(bindings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(bindings.toJson()));
  }

  Future<void> reset() async {
    state = AsyncData(Keybindings.defaults);
    await (await SharedPreferences.getInstance()).remove(_key);
  }
}
