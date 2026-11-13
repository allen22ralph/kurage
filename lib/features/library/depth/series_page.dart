import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/card_look.dart';
import '../../../app/layout.dart';
import '../../../app/smooth_wheel.dart';
import '../../../core/jellyfin/items.dart';
import '../../anime/widgets/mal_widgets.dart';
import '../../downloads/downloads_screen.dart';
import '../../home/depth/deck_hero.dart';
import '../../home/depth/drum_section.dart';
import '../../home/depth/preview.dart';
import '../../seerr/missing_seasons.dart';
import '../item_detail_screen.dart';
import '../library_providers.dart';
import '../navigation.dart';
import '../widgets/item_image.dart';
import '../widgets/media_row.dart';
import '../widgets/add_to_playlist.dart';
import 'detail_parts.dart';

/// Depth's page for a series or, without the episodes, a film.
class DepthSeriesPage extends ConsumerStatefulWidget {
  const DepthSeriesPage({super.key, required this.item, this.seasonId});

  final BaseItem item;
  final String? seasonId;

  @override
  ConsumerState<DepthSeriesPage> createState() => _DepthSeriesPageState();
}

class _DepthSeriesPageState extends ConsumerState<DepthSeriesPage> with ItemToggles {
  @override
  BaseItem get togglesItem => widget.item;

  /// "S1", following the season picked below.
  final _season = ValueNotifier<String?>(null);
  bool _hovering = false;

  @override
  void didUpdateWidget(DepthSeriesPage old) {
    super.didUpdateWidget(old);
    if (old.item != widget.item) syncToggles();
  }

  @override
  void dispose() {
    _season.dispose();
    super.dispose();
  }

  bool get _isSeries => widget.item.type == ItemType.series;

  /// The hero's main button.
  Widget _main({required bool expand}) {
    final item = widget.item;
    if (_isSeries) {
      final action = seriesMainAction(ref, item.id);
      if (action == null) return const SizedBox.shrink();
      final episode = action.episode;
      final resumed = episode.userData.hasProgress;
      final at = formatPosition(ticksToDuration(episode.userData.playbackPositionTicks));
      return ResumePill(
        expand: expand,
        autofocus: true,
        label: '${action.verb} ${episode.episodeLabel ?? episode.name}',
        detail: resumed ? '· $at' : null,
        progress: resumed ? watchedFraction(episode) : 0,
        onPressed: () => openItem(context, episode, play: true),
      );
    }
    final resumed = toggleData.hasProgress;
    return ResumePill(
      expand: expand,
      autofocus: true,
      label: resumed ? 'Resume from ${formatPosition(ticksToDuration(toggleData.playbackPositionTicks))}' : 'Play',
      detail: resumed ? timeLeft(item)?.replaceFirst(RegExp('^'), '· ') : null,
      progress: resumed ? watchedFraction(item) : 0,
      onPressed: () => openItem(context, item, play: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final item = widget.item;
    final people = item.people;
    return SmoothWheel(
      builder: (_, wheel) => ListView(
        controller: wheel,
        padding: EdgeInsets.zero,
        children: [
          if (phone) _phoneHero(context) else _pcHero(context),
          if (phone) _phoneActions(context) else _pcActions(context),
          _Page(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: phone ? 22 : 80),
                // On a phone it starts just under the buttons, in the first
                // screen: rolling in, it would be missing until scrolled to.
                if (phone) _About(item: item) else DrumSection(child: _About(item: item)),
                if (_isSeries) ...[
                  SizedBox(height: phone ? 26 : 80),
                  SeasonsAndEpisodes(series: item, initialSeasonId: widget.seasonId, depth: true, seasonLabel: _season),
                ],
                if (people.isNotEmpty) ...[
                  SizedBox(height: phone ? 26 : 80),
                  DrumSection(child: DepthCastRow(people: people)),
                ],
              ],
            ),
          ),
          MediaRow(
            title: 'More like this',
            items: ref.watch(similarProvider(item.id)),
            onItemPressed: (other) => openItem(context, other),
          ),
          SizedBox(height: phone ? 48 : 120),
        ],
      ),
    );
  }

  /// The item's trailer of its own, if any: what plays over the hero.
  BaseItem? get _trailer => ref.watch(localTrailersProvider(widget.item.id)).value?.firstOrNull;

  Widget _pcHero(BuildContext context) {
    final item = widget.item;
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 760;
    final studio = item.studios.firstOrNull;
    final vertical = [?studio, ?item.yearLabel].join(' · ');
    final big = narrow ? 150.0 : 250.0;
    return _Page(
      top: 96,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          MouseRegion(
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: Container(
              height: narrow ? 460 : 600,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(32),
                boxShadow: [BoxShadow(color: const Color(0xFF8F84FF).withValues(alpha: 0.55), blurRadius: 100, spreadRadius: -50, offset: const Offset(0, 50))],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  HeroPicture(
                    image: item.backdropImage ?? item.landscapeImage,
                    maxWidth: width,
                    preview: _trailer,
                    previewLabel: 'Trailer',
                    hovering: _hovering,
                    overlay: const _PcShade(),
                  ),
                  if (vertical.isNotEmpty && !narrow)
                    Positioned(
                      right: 22,
                      top: 26,
                      child: IgnorePointer(
                        child: RotatedBox(
                          quarterTurns: 1,
                          child: Text(
                            vertical.toUpperCase(),
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 3.5),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: math.max(24, math.min(56, width * 0.04)),
                    right: narrow ? 24 : 260,
                    top: 24,
                    bottom: 48,
                    child: LayoutBuilder(
                      builder: (context, box) => Align(
                        alignment: Alignment.bottomLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.bottomLeft,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: math.min(box.maxWidth, 760)),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _HeroText(item: item, small: false, label: _label()),
                                const SizedBox(height: 26),
                                RiseIn(
                                  delay: 240,
                                  child: GhostTheme(
                                    child: Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: [
                                        _main(expand: false),
                                        if (!_isSeries && toggleData.hasProgress)
                                          GhostButton(
                                            icon: Icons.replay_rounded,
                                            label: 'From start',
                                            onPressed: () => context.push('/play/${item.id}?fromStart=1'),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_isSeries)
            Positioned(
              right: 28,
              bottom: -big * 0.21,
              child: ValueListenableBuilder<String?>(
                valueListenable: _season,
                builder: (context, season, _) => season == null ? const SizedBox.shrink() : BigNumber(season, size: big),
              ),
            ),
        ],
      ),
    );
  }

  /// Under a PC's hero: marking, favorite, download. Clear of the big number
  /// that hangs below the hero's right side.
  Widget _pcActions(BuildContext context) {
    final item = widget.item;
    final narrow = MediaQuery.sizeOf(context).width < 760;
    return _Page(
      // (A page centres what's narrower than it.)
      child: SizedBox(
        width: double.infinity,
        child: Padding(
        padding: EdgeInsets.only(top: 28, right: narrow ? 190 : 360),
        child: RiseIn(
          delay: 300,
          child: GhostTheme(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                GhostButton(
                  icon: toggleData.played ? Icons.check_circle : Icons.check_circle_outline,
                  label: _watchedLabel(),
                  on: toggleData.played,
                  onPressed: () => toggleItem(played: !toggleData.played),
                ),
                GhostButton(
                  icon: toggleData.likes ? Icons.bookmark : Icons.bookmark_border,
                  label: toggleData.likes ? 'On watchlist' : 'Watchlist',
                  on: toggleData.likes,
                  onPressed: () => toggleItem(watchlist: !toggleData.likes),
                ),
                FavoriteButton(
                  favorite: toggleData.isFavorite,
                  onPressed: () => toggleItem(favorite: !toggleData.isFavorite),
                ),
                if (canDownload(item)) DownloadButton(item: item),
                GhostButton(
                  icon: Icons.playlist_add,
                  label: 'Add to playlist',
                  onPressed: () => showAddToPlaylist(context, [item]),
                ),
                if (_isSeries) SeriesRequestButton(series: item),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  String _watchedLabel() => switch ((_isSeries, toggleData.played)) {
        (true, true) => 'Series watched',
        (true, false) => 'Mark series watched',
        (false, true) => 'Watched',
        (false, false) => 'Mark watched',
      };

  String _label() {
    final item = widget.item;
    if (_isSeries) return seriesLabel(ref.watch(seasonsProvider(item.id)).value);
    return ['Movie', if (item.runtime case final r?) formatRuntime(r)].join(' · ');
  }

  Widget _phoneHero(BuildContext context) {
    final item = widget.item;
    final width = MediaQuery.sizeOf(context).width;
    return SizedBox(
      height: 380 + statusBarHeight(context),
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          HeroPicture(
            image: item.backdropImage ?? item.landscapeImage,
            maxWidth: width,
            preview: _trailer,
            previewLabel: 'Trailer',
            hovering: false,
            playsBySelf: previewsPlayBySelf(context),
            chipRight: 16,
            // Below the top bar.
            chipTop: statusBarHeight(context) + 62,
            overlay: const _PhoneShade(),
          ),
          if (_isSeries)
            Positioned(
              right: 8,
              top: 110 + statusBarHeight(context),
              child: ValueListenableBuilder<String?>(
                valueListenable: _season,
                builder: (context, season, _) => season == null ? const SizedBox.shrink() : BigNumber(season, size: 96),
              ),
            ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: _HeroText(item: item, small: true, label: _label()),
          ),
        ],
      ),
    );
  }

  Widget _phoneActions(BuildContext context) {
    final item = widget.item;
    final trailer = _trailer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RiseIn(delay: 240, child: _main(expand: true)),
          const SizedBox(height: 14),
          RiseIn(
            delay: 360,
            child: RoundActions(
              children: [
                RoundAction(
                  label: toggleData.played ? 'Watched' : 'Mark watched',
                  icon: toggleData.played ? Icons.check_circle : Icons.check_circle_outline,
                  on: toggleData.played,
                  onPressed: () => toggleItem(played: !toggleData.played),
                ),
                RoundAction(
                  label: 'Playlist',
                  icon: Icons.playlist_add,
                  onPressed: () => showAddToPlaylist(context, [item]),
                  ),
                  RoundAction(
                  label: 'Watchlist',
                  icon: toggleData.likes ? Icons.bookmark : Icons.bookmark_border,
                  on: toggleData.likes,
                  onPressed: () => toggleItem(watchlist: !toggleData.likes),
                ),
                RoundAction(
                  label: 'Favorite',
                  icon: toggleData.isFavorite ? Icons.favorite : Icons.favorite_border,
                  on: toggleData.isFavorite,
                  onColour: const Color(0xFFFF9EC4),
                  onPressed: () => toggleItem(favorite: !toggleData.isFavorite),
                ),
                if (canDownload(item))
                  _isSeries
                      ? RoundAction(label: 'Download', icon: Icons.download_outlined, onPressed: () => startDownload(context, item))
                      : RoundAction(label: 'Download', child: EpisodeDownloadButton(episode: item)),
                if (trailer != null)
                  RoundAction(label: 'Trailer', icon: Icons.smart_display_outlined, onPressed: () => context.push('/play/${trailer.id}')),
              ],
            ),
          ),
          if (_isSeries) ...[
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: GhostTheme(height: 44, child: SeriesRequestButton(series: item))),
          ],
        ],
      ),
    );
  }
}

/// A page's width and margins. A phone has its own gutter and no limit.
class _Page extends StatelessWidget {
  const _Page({required this.child, this.top = 0});

  final Widget child;
  final double top;

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final side = phone ? 16.0 : MediaQuery.sizeOf(context).width * 0.034;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: Padding(
          padding: EdgeInsets.fromLTRB(side.clamp(16.0, 44.0), top, side.clamp(16.0, 44.0), 0),
          child: child,
        ),
      ),
    );
  }
}

class _PcShade extends StatelessWidget {
  const _PcShade();

  @override
  Widget build(BuildContext context) => const Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                stops: [0, 0.42, 0.75],
                colors: [Color(0xEB06070B), Color(0x8006070B), Color(0x0D06070B)],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                stops: [0, 0.45],
                colors: [Color(0xD906070B), Color(0x0006070B)],
              ),
            ),
          ),
        ],
      );
}

class _PhoneShade extends StatelessWidget {
  const _PhoneShade();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0, 0.3, 0.62, 1],
            colors: [Color(0x5906070B), Color(0x0006070B), Color(0x9906070B), Color(0xFF06070B)],
          ),
        ),
      );
}

/// The label, logo or title, second line and meta.
class _HeroText extends ConsumerWidget {
  const _HeroText({required this.item, required this.small, required this.label});

  final BaseItem item;
  final bool small;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = CardLook.headingStyle(context) ?? const TextStyle();
    final logo = item.logoImage;
    final title = preferredAnimeTitle(ref, item, item.name);
    final titleStyle = display.copyWith(
      fontSize: small ? 46 : (MediaQuery.sizeOf(context).width < 760 ? 40 : 76),
      fontWeight: FontWeight.w800,
      color: Colors.white,
      height: 0.95,
      letterSpacing: small ? 1 : 2,
      shadows: const [Shadow(color: Color(0x99000000), blurRadius: 40, offset: Offset(0, 6))],
    );
    final second = detailSecondLine(ref, item, showsLogo: logo != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        RiseIn(delay: 0, child: Kick(label)),
        SizedBox(height: small ? 8 : 16),
        if (logo != null)
          RiseIn(
            delay: 60,
            child: SizedBox(
              height: small ? 80 : 120,
              width: small ? 300 : 460,
              child: ItemImage(
                image: logo,
                maxWidth: small ? 300 : 460,
                fit: BoxFit.contain,
                alignment: Alignment.bottomLeft,
                placeholder: Text(title, style: titleStyle, maxLines: 2),
              ),
            ),
          )
        else
          TrackingTitle(title, style: titleStyle),
        if (second != null)
          RiseIn(
            delay: 120,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                second,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: display.copyWith(color: const Color(0xFFE8E9F0), fontSize: small ? 18 : 26, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        SizedBox(height: small ? 10 : 16),
        RiseIn(
          delay: 120,
          child: HeroMeta(
            small: small,
            children: [
              if (item.yearLabel case final year?) Text(year),
              if (item.officialRating case final rating?) RatingBadge(rating, small: small),
              if (item.communityRating case final score?) StarScore(score, small: small),
              if (item.genres.isNotEmpty)
                Text(
                  item.genres.take(3).join(' · '),
                  style: const TextStyle(color: Color(0xFFA8ADBD), fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// About (overview, tags, studios) and MyAnimeList.
class _About extends StatefulWidget {
  const _About({required this.item});

  final BaseItem item;

  @override
  State<_About> createState() => _AboutState();
}

class _AboutState extends State<_About> {
  bool _allStudios = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final phone = context.layout.formFactor == FormFactor.phone;
    final tags = item.tags;
    final studios = item.studios;
    final overview = item.overview ?? '';
    final about = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Kick(item.type == ItemType.series ? 'About the series' : 'About the film'),
        if (item.taglines.firstOrNull case final tagline?)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(tagline, style: const TextStyle(color: Color(0xFFE8E9F0), fontSize: 16, fontStyle: FontStyle.italic)),
          ),
        if (overview.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 14), child: DepthOverview(text: overview)),
        if (tags.isNotEmpty || item.genres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (tags.isNotEmpty)
                  for (final tag in tags.take(12)) DetailChip(tag)
                else
                  for (final genre in item.genres) DetailChip(genre, onPressed: () => context.push('/genre/${Uri.encodeComponent(genre)}')),
              ],
            ),
          ),
        if (studios.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Kick('Studios & networks', muted: true),
                const SizedBox(height: 8),
                Text(
                  (_allStudios ? studios : studios.take(5)).join(' · '),
                  style: const TextStyle(color: Color(0xFFB9BDCC), fontSize: 13, height: 1.7),
                ),
                if (studios.length > 5)
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      minimumSize: Size.zero,
                      foregroundColor: const Color(0xFFB9B2FF),
                      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                    onPressed: () => setState(() => _allStudios = !_allStudios),
                    child: Text(_allStudios ? 'Show less' : 'Show all ${studios.length}'),
                  ),
              ],
            ),
          ),
      ],
    );
    final mal = MalPanel(item: item, columns: phone ? 4 : 2);
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < detailOneColumnBelow - 100) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [about, mal],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 7, child: about),
            const SizedBox(width: 40),
            Expanded(flex: 4, child: mal),
          ],
        );
      },
    );
  }
}
