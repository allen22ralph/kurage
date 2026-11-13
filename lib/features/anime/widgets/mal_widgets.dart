import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/anime/anime_info.dart';
import '../../../core/jellyfin/items.dart';
import '../anime_providers.dart';
import '../mal_account.dart';
import '../anime_settings.dart';
import '../../../theme/app_tokens.dart';

String _compact(int n) => n >= 1000000
    ? '${(n / 1000000).toStringAsFixed(1)}M'
    : n >= 1000
        ? '${(n / 1000).round()}K'
        : '$n';

bool _showScores(WidgetRef ref) =>
    ref.watch(animeSettingsProvider).value?.showScores ?? true;

/// "★ 8.2" in a card's top-left corner when the item has a MAL score:
/// the show's (out of 10), or for an episode its own community rating
/// (out of 5).
class MalScoreBadge extends ConsumerWidget {
  const MalScoreBadge({super.key, required this.item});

  final BaseItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_showScores(ref)) return const SizedBox.shrink();
    final number = item.indexNumber;
    final episode = item.type == ItemType.episode;
    final settings = ref.watch(animeSettingsProvider).value ?? const AnimeSettings();
    final episodeScore = episode
        ? switch (number == null ? null : ref.watch(episodeScoreProvider((animeKeyOf(item), number))).value) {
            final double raw => settings.episodeScore(raw),
            null => null,
          }
        : null;
    // An episode without a rating (too new, or not listed): the show's
    // score, marked as the show's.
    final showScore = episode && episodeScore == null && item.seriesId != null
        ? ref.watch(seriesAnimeInfoProvider(item.seriesId!)).value?.score
        : null;
    final score = episode ? episodeScore ?? showScore : ref.watch(animeForItemProvider(animeKeyOf(item))).value?.info?.score;
    if (score == null) return const SizedBox.shrink();
    final ofShow = episode && episodeScore == null;
    final scale = episode && !ofShow && !settings.episodeScoresOutOf10 ? 5 : 10;
    return Positioned(
      top: 6,
      left: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.star_rounded, size: 14, color: context.tokens.star),
              const SizedBox(width: 2),
              Text(
                score.toStringAsFixed(2),
                semanticsLabel: ofShow
                    ? "MyAnimeList show score $score (this episode isn't rated yet)"
                    : episode
                        ? 'MyAnimeList episode rating $score out of $scale'
                        : 'MyAnimeList score $score',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              if (ofShow)
                const Padding(
                  padding: EdgeInsets.only(left: 3),
                  child: Text('show', style: TextStyle(color: Colors.white70, fontSize: 10)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "★ 4.76" (MAL's community episode rating, out of 5) for an episode row.
class MalEpisodeScore extends ConsumerWidget {
  const MalEpisodeScore({super.key, required this.episode});

  final BaseItem episode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final number = episode.indexNumber;
    if (!_showScores(ref) || number == null) return const SizedBox.shrink();
    final raw = ref.watch(episodeScoreProvider((animeKeyOf(episode), number))).value;
    if (raw == null) return const SizedBox.shrink();
    final settings = ref.watch(animeSettingsProvider).value ?? const AnimeSettings();
    final score = settings.episodeScore(raw);
    final scale = settings.episodeScoresOutOf10 ? 10 : 5;
    final theme = Theme.of(context);
    return Tooltip(
      message: settings.episodeScoresOutOf10
          ? 'MyAnimeList community rating, ${raw.toStringAsFixed(2)}/5 doubled'
          : 'MyAnimeList community rating, out of 5',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 16, color: context.tokens.star),
          const SizedBox(width: 2),
          Text(
            score.toStringAsFixed(2),
            semanticsLabel: 'MyAnimeList episode rating $score out of $scale',
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// MyAnimeList facts for a detail page: score, rank, popularity, members,
/// a link to MAL and "Fix match". Offers "Find on MyAnimeList" for series
/// and movies that didn't match.
class MalDetails extends ConsumerWidget {
  const MalDetails({super.key, required this.item, this.label, this.unlessSameAs});

  final BaseItem item;

  /// Shown before the facts, e.g. the season name.
  final String? label;

  /// Hide when this item (the series) is the same MAL entry, so a first
  /// season doesn't repeat the series' row. Also hides "not matched".
  final BaseItem? unlessSameAs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_showScores(ref)) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final result = ref.watch(animeForItemProvider(animeKeyOf(item)));
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    if (result.isLoading) return const SizedBox(height: 40);
    final anime = result.value;
    if (unlessSameAs case final other?) {
      final otherMatch = ref.watch(malMatchProvider(animeKeyOf(other))).value;
      if (anime == null || anime.match.malId == otherMatch?.malId) return const SizedBox.shrink();
    }
    if (anime == null) {
      if (item.type != ItemType.series && item.type != ItemType.movie && item.type != ItemType.season) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text('${label == null ? '' : '$label · '}Not matched on MyAnimeList', style: muted),
            TextButton(
              onPressed: () => showFixMatchDialog(context, item),
              child: const Text('Find match'),
            ),
          ],
        ),
      );
    }

    final info = anime.info;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 4,
        children: [
          if (label != null) Text(label!, style: theme.textTheme.titleSmall),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.star_rounded, size: 20, color: context.tokens.star),
              const SizedBox(width: 4),
              Text(
                info?.score?.toStringAsFixed(2) ?? 'N/A',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 6),
              Text('MyAnimeList', style: muted),
            ],
          ),
          if (info?.rank case final r?) Text('Ranked #$r', style: muted),
          if (info?.popularity case final p?) Text('Popularity #$p', style: muted),
          if (info?.members case final m?) Text('${_compact(m)} members', style: muted),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: () => launchUrl(
                  info?.url ?? Uri.parse('https://myanimelist.net/anime/${anime.match.malId}'),
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('MyAnimeList'),
              ),
              TextButton(
                onPressed: () => showFixMatchDialog(context, item),
                child: const Text('Fix match'),
              ),
            ],
          ),
          if (item.type == ItemType.series) _SyncOptOut(seriesId: item.id),
        ],
      ),
    );
  }
}

/// Per-show switch for MyAnimeList updates, when an account is linked.
/// Depth's MyAnimeList block: its links, the numbers as tiles, and for a show
/// the switch for updating MyAnimeList.
class MalPanel extends ConsumerWidget {
  const MalPanel({super.key, required this.item, this.columns = 2});

  final BaseItem item;
  final int columns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_showScores(ref)) return const SizedBox.shrink();
    final result = ref.watch(animeForItemProvider(animeKeyOf(item)));
    if (result.isLoading) return const SizedBox.shrink();
    final anime = result.value;
    final episode = item.type == ItemType.episode;
    if (anime == null && episode) return const SizedBox.shrink();
    final muted = context.tokens.textMuted ?? const Color(0xFF9AA0B2);
    final small = columns > 2 && MediaQuery.sizeOf(context).width < 600;
    final link = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 32),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    );
    final heading = Row(
      children: [
        Text(
          'MYANIMELIST',
          style: TextStyle(color: muted, fontSize: small ? 11 : 12, fontWeight: FontWeight.w800, letterSpacing: small ? 2.2 : 2.6),
        ),
        const SizedBox(width: 12),
        Expanded(child: ColoredBox(color: Colors.white.withValues(alpha: 0.1), child: const SizedBox(height: 1))),
        if (anime != null)
          TextButton(
            style: link,
            onPressed: () => launchUrl(anime.info?.url ?? Uri.parse('https://myanimelist.net/anime/${anime.match.malId}')),
            child: const Text('Open'),
          ),
        TextButton(
          style: link.merge(TextButton.styleFrom(foregroundColor: muted)),
          onPressed: () => showFixMatchDialog(context, item),
          child: Text(anime == null ? 'Find match' : 'Fix match'),
        ),
      ],
    );
    if (anime == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading,
            Text('Not matched on MyAnimeList', style: TextStyle(color: muted, fontSize: 13)),
          ],
        ),
      );
    }
    final info = anime.info;
    final tiles = [
      _StatTile(value: info?.score?.toStringAsFixed(2) ?? 'N/A', label: 'Score', star: !small, small: small),
      if (info?.rank case final r?) _StatTile(value: '#$r', label: 'Ranked', small: small),
      if (info?.popularity case final p?) _StatTile(value: '#$p', label: small ? 'Popular' : 'Popularity', small: small),
      if (info?.members case final m?) _StatTile(value: _compact(m), label: 'Members', small: small),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading,
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, box) {
              final gap = small ? 6.0 : 12.0;
              final width = (box.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [for (final t in tiles) SizedBox(width: width, child: t)],
              );
            },
          ),
          if (item.type == ItemType.series) _SyncOptOutRow(seriesId: item.id),
        ],
      ),
    );
  }
}

class _StatTile extends StatefulWidget {
  const _StatTile({required this.value, required this.label, this.star = false, this.small = false});

  final String value;
  final String label;
  final bool star;
  final bool small;

  @override
  State<_StatTile> createState() => _StatTileState();
}

class _StatTileState extends State<_StatTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final small = widget.small;
    final value = Text(
      widget.value,
      maxLines: 1,
      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: Colors.white,
            fontSize: small ? 18 : 36,
            fontWeight: FontWeight.w800,
            letterSpacing: small ? 0 : -1,
            height: 1,
          ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedSlide(
        offset: Offset(0, _hover ? -0.05 : 0),
        duration: const Duration(milliseconds: 300),
        child: Container(
          padding: small ? const EdgeInsets.symmetric(horizontal: 6, vertical: 12) : const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xFF0C0E15),
            borderRadius: BorderRadius.circular(small ? 14 : 20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Column(
            crossAxisAlignment: small ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.star) ...[Icon(Icons.star_rounded, size: 26, color: context.tokens.star), const SizedBox(width: 6)],
                    value,
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.tokens.textMuted ?? const Color(0xFF9AA0B2),
                  fontSize: small ? 9 : 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.7,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [_SyncOptOut], in a panel.
class _SyncOptOutRow extends ConsumerWidget {
  const _SyncOptOutRow({required this.seriesId});

  final String seriesId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(malAccountProvider).value == null) return const SizedBox.shrink();
    final optedOut = ref.watch(malSyncOptOutProvider).value?.contains(seriesId) ?? false;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0C0E15),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Update MyAnimeList for this show', style: TextStyle(color: Color(0xFFE8E9F0), fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('Syncs your watched episodes', style: TextStyle(color: context.tokens.textMuted ?? const Color(0xFF9AA0B2), fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Switch(
            value: !optedOut,
            onChanged: (v) => ref.read(malSyncOptOutProvider.notifier).setSynced(seriesId, v),
          ),
        ],
      ),
    );
  }
}

class _SyncOptOut extends ConsumerWidget {
  const _SyncOptOut({required this.seriesId});

  final String seriesId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(malAccountProvider).value == null) return const SizedBox.shrink();
    final optedOut = ref.watch(malSyncOptOutProvider).value?.contains(seriesId) ?? false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(
          value: !optedOut,
          onChanged: (v) => ref.read(malSyncOptOutProvider.notifier).setSynced(seriesId, v),
        ),
        const SizedBox(width: 4),
        const Text('Update MyAnimeList for this show'),
      ],
    );
  }
}

/// Lets the user pick the right MAL entry by searching MAL (Jikan), or go
/// back to automatic matching.
Future<void> showFixMatchDialog(BuildContext context, BaseItem item) =>
    showDialog<void>(context: context, builder: (_) => _FixMatchDialog(item: item));

class _FixMatchDialog extends ConsumerStatefulWidget {
  const _FixMatchDialog({required this.item});

  final BaseItem item;

  @override
  ConsumerState<_FixMatchDialog> createState() => _FixMatchDialogState();
}

class _FixMatchDialogState extends ConsumerState<_FixMatchDialog> {
  late final _query = TextEditingController(text: widget.item.seriesName ?? widget.item.name);
  List<AnimeInfo>? _results;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await searchAnime(ref, q);
      if (mounted) setState(() => _results = results);
    } on Object catch (e) {
      if (mounted) setState(() => _error = "Couldn't search MyAnimeList: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(int? malId) async {
    await ref.read(malOverridesProvider.notifier).set(widget.item.id, malId);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(malMatchProvider(animeKeyOf(widget.item))).value;
    final results = _results;
    return AlertDialog(
      title: Text('MyAnimeList match for ${widget.item.name}'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (current != null)
              Text('Now: MAL #${current.malId} (${current.source.label})'),
            const SizedBox(height: 12),
            TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: 'Search MyAnimeList',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search),
                  onPressed: _busy ? null : _search,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (results != null && results.isEmpty) const Text('No results.'),
            for (final r in results ?? const <AnimeInfo>[])
              ListTile(
                contentPadding: EdgeInsets.zero,
                selected: r.malId == current?.malId,
                title: Text(r.title),
                subtitle: Text([
                  ?r.type,
                  if (r.episodes case final e?) '$e eps',
                  if (r.score case final s?) '★ ${s.toStringAsFixed(2)}',
                  if (r.titleEnglish case final en? when en != r.title) en,
                ].join(' · ')),
                onTap: () => _choose(r.malId),
              ),
          ],
        ),
      ),
      actions: [
        if (current?.source.name == 'manual')
          TextButton(onPressed: () => _choose(null), child: const Text('Use automatic match')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}

/// [fallback] (the server's title) unless the user prefers MAL's Romaji,
/// English or Japanese title and [item] is matched. For an episode this is
/// the title of its season's MAL entry (shown where the series name is).
/// An episode's title in the chosen language, from MAL's episode list;
/// [fallback] (the server's) when the setting is "as on the server" or MAL
/// has none.
String preferredEpisodeTitle(WidgetRef ref, BaseItem episode, String fallback) {
  final language = ref.watch(animeSettingsProvider).value?.titleLanguage ?? TitleLanguage.server;
  final number = episode.indexNumber;
  if (language == TitleLanguage.server || episode.type != ItemType.episode || number == null) {
    return fallback;
  }
  final mal = ref.watch(malEpisodeProvider((animeKeyOf(episode), number))).value;
  final title = switch (language) {
    TitleLanguage.english => mal?.title,
    TitleLanguage.romaji => mal?.romaji,
    TitleLanguage.japanese => mal?.japanese,
    TitleLanguage.server => null,
  };
  return title ?? fallback;
}

String preferredAnimeTitle(WidgetRef ref, BaseItem item, String fallback) {
  final language = ref.watch(animeSettingsProvider).value?.titleLanguage ?? TitleLanguage.server;
  if (language == TitleLanguage.server) return fallback;
  if (!const {ItemType.series, ItemType.movie, ItemType.episode}.contains(item.type)) {
    return fallback;
  }
  // An episode carries its show's name: the show's MAL entry, not the
  // season's ("The Apothecary Diaries", not "… Season 2").
  final info = item.type == ItemType.episode
      ? switch (item.seriesId) {
          final id? => ref.watch(seriesAnimeInfoProvider(id)).value,
          null => null,
        }
      : ref.watch(animeForItemProvider(animeKeyOf(item))).value?.info;
  if (info == null) return fallback;
  final title = switch (language) {
    TitleLanguage.romaji => info.title,
    TitleLanguage.english => info.titleEnglish,
    TitleLanguage.japanese => info.titleJapanese,
    TitleLanguage.server => null,
  };
  return title == null || title.trim().isEmpty ? fallback : title;
}
