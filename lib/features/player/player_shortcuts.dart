import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../settings/keybindings.dart';

/// Turns the user's [Keybindings] into shortcuts for the player.
///
/// Passed to media_kit's controls as their `keyboardShortcuts`, replacing its
/// built-in map: its controls see keys first, so shortcuts placed around
/// them would never fire for keys it also binds.
Map<ShortcutActivator, VoidCallback> playerShortcuts(
  Keybindings bindings,
  Map<PlayerAction, VoidCallback> actions, {
  bool systemMediaKeys = false,
}) =>
    {
      for (final MapEntry(key: action, value: keys) in bindings.entries)
        if (actions[action] case final run?)
          for (final key in keys)
            // With system media controls (Windows), media keys arrive
            // through them; binding them here too would act twice.
            if (!systemMediaKeys || !_mediaKeys.contains(key.trigger)) key: run,
    };

final _mediaKeys = {
  LogicalKeyboardKey.mediaPlayPause,
  LogicalKeyboardKey.mediaPlay,
  LogicalKeyboardKey.mediaPause,
  LogicalKeyboardKey.mediaStop,
  LogicalKeyboardKey.mediaTrackNext,
  LogicalKeyboardKey.mediaTrackPrevious,
};
