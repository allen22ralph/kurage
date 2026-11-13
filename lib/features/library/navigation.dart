import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../core/jellyfin/items.dart';

/// Opens [item] in the right place: a library grid for views, the series
/// page for seasons, the player when [play] is set, otherwise details.
void openItem(BuildContext context, BaseItem item, {bool play = false}) {
  if (play && item.type.isPlayable) {
    context.push('/play/${item.id}');
    return;
  }
  switch (item.type) {
    case ItemType.collectionFolder || ItemType.userView:
      context.push('/library/${item.id}');
    case ItemType.season when item.seriesId != null:
      context.push('/item/${item.seriesId}?season=${item.id}');
    default:
      context.push('/item/${item.id}');
  }
}

/// The show an episode belongs to, opened at the episode's season.
void openSeries(BuildContext context, BaseItem episode) {
  final seriesId = episode.seriesId;
  if (seriesId == null) return openItem(context, episode);
  final season = episode.seasonId;
  context.push('/item/$seriesId${season == null ? '' : '?season=$season'}');
}

/// An episode's own page (details, not the player).
void openEpisode(BuildContext context, BaseItem episode) =>
    context.push('/item/${episode.id}');

/// Leaves the player: back to the page it was opened from (Home if there's
/// none, as when it was opened from outside the app).
void exitPlayer(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/');
  }
}

/// Leaves the player for the page at [path], in the player's place: Back
/// from there goes where Back from the player would have.
void exitPlayerTo(BuildContext context, String path) => context.pushReplacement(path);

/// The page of an episode's show, at the episode's season.
String seriesPathOf(BaseItem episode) {
  final season = episode.seasonId;
  return '/item/${episode.seriesId}${season == null ? '' : '?season=$season'}';
}
