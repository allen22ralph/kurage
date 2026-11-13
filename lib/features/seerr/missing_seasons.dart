import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/jellyfin/items.dart';
import '../../core/seerr/seerr_api.dart';
import 'request_window.dart';
import 'seerr_providers.dart';

/// A show's TMDB id (how Seerr knows it), from Jellyfin's provider ids.
int? tmdbIdOf(BaseItem item) {
  for (final MapEntry(:key, :value) in item.providerIds.entries) {
    if (key.toLowerCase() == 'tmdb') return int.tryParse(value);
  }
  return null;
}

/// Seerr's view of a library show (its seasons and their status); null when
/// not signed in to Seerr, the show has no TMDB id, or Seerr can't be asked.
final librarySeriesInSeerrProvider = FutureProvider.autoDispose.family<SeerrDetails?, int>((ref, tmdbId) async {
  if (ref.watch(seerrAccountProvider).value == null) return null;
  try {
    return await ref.watch(seerrDetailsProvider((type: SeerrMediaType.tv, tmdbId: tmdbId)).future);
  } on Object {
    return null;
  }
});

SeerrDetails? _details(WidgetRef ref, BaseItem series) {
  final tmdbId = tmdbIdOf(series);
  return tmdbId == null ? null : ref.watch(librarySeriesInSeerrProvider(tmdbId)).value;
}

bool _canRequest(WidgetRef ref) =>
    ref.watch(seerrAccountProvider).value?.user.canRequest(SeerrMediaType.tv) ?? false;

void _openRequest(BuildContext context, SeerrDetails details) {
  final box = context.findRenderObject() as RenderBox?;
  showSeerrRequest(context, details.media, from: box == null ? null : box.localToGlobal(Offset.zero) & box.size);
}

/// The show page's Request button (#98): the request window with the seasons
/// that aren't on the server ticked. Not shown when nothing is missing.
class SeriesRequestButton extends ConsumerWidget {
  const SeriesRequestButton({super.key, required this.series});

  final BaseItem series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = _details(ref, series);
    if (details == null || !_canRequest(ref)) return const SizedBox.shrink();
    final missing = details.seasons.where((s) => s.status.requestable).toList();
    if (missing.isEmpty) return const SizedBox.shrink();
    return OutlinedButton.icon(
      icon: const Icon(Icons.add_circle_outline),
      label: Text(missing.length == 1 ? 'Request ${missing.single.name}' : 'Request missing seasons (${missing.length})'),
      onPressed: () => _openRequest(context, details),
    );
  }
}

/// Seasons Seerr knows that aren't on the server, beside the season chips:
/// "Season 3 · Not on server" (tap to request), or its request's state.
class SeasonsNotOnServer extends ConsumerWidget {
  const SeasonsNotOnServer({super.key, required this.series, required this.onServer});

  final BaseItem series;

  /// Season numbers the server has.
  final Set<int> onServer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = _details(ref, series);
    if (details == null) return const SizedBox.shrink();
    final absent = [
      for (final s in details.seasons)
        if (!onServer.contains(s.number)) s,
    ];
    if (absent.isEmpty) return const SizedBox.shrink();
    final canRequest = _canRequest(ref);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final s in absent)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              avatar: Icon(s.status.requestable ? Icons.add : Icons.schedule, size: 18, color: muted),
              label: Text('${s.name} · ${s.status.requestable ? 'Not on server' : s.status.label}',
                  style: TextStyle(color: muted)),
              tooltip: s.status.requestable && canRequest ? 'Request ${s.name}' : null,
              onPressed: s.status.requestable && canRequest ? () => _openRequest(context, details) : null,
            ),
          ),
      ],
    );
  }
}

/// Under a season the server has only part of: how many episodes it has
/// of how many there are, and what can be done about the rest.
class MissingEpisodesNote extends ConsumerWidget {
  const MissingEpisodesNote({super.key, required this.series, required this.seasonNumber, required this.onServer});

  final BaseItem series;
  final int? seasonNumber;

  /// Episodes of the season on the server.
  final int onServer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = _details(ref, series);
    final season = details?.seasons.where((s) => s.number == seasonNumber).firstOrNull;
    final total = season?.episodeCount;
    if (details == null || season == null || total == null || onServer >= total) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final canRequest = season.status.requestable && _canRequest(ref);
    final why = switch (season.status) {
      _ when canRequest => null,
      SeerrMediaStatus.pending || SeerrMediaStatus.processing => 'Requested: waiting for the rest to download.',
      _ when season.status.requestable => "You can't request shows on Seerr.",
      // Seerr counts the season as there: it won't take a new request.
      _ => "Seerr counts this season as available, so it won't take a new request; Sonarr can search for the "
          'missing episodes.',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
          Text('$onServer of $total episodes are on the server.', style: muted),
          if (why != null) Text(why, style: muted),
          if (canRequest)
            TextButton.icon(
              icon: const Icon(Icons.add_circle_outline, size: 18),
              label: Text('Request the rest of ${season.name}'),
              onPressed: () => _openRequest(context, details),
            ),
        ],
      ),
    );
  }
}
