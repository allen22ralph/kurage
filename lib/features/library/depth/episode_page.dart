import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/layout.dart';
import '../../../app/smooth_wheel.dart';
import '../../../core/jellyfin/items.dart';
import '../../anime/widgets/mal_widgets.dart';
import '../../downloads/downloads_screen.dart';
import '../../home/depth/deck_hero.dart';
import '../../home/depth/drum_section.dart';
import '../../home/depth/expanding_row.dart';
import '../../home/home_components.dart';
import '../item_detail_screen.dart';
import '../library_providers.dart';
import '../navigation.dart';
import '../widgets/item_image.dart';
import '../widgets/side_scroll.dart';
import '../widgets/add_to_playlist.dart';
import 'detail_parts.dart';
import 'episode_rows.dart';

/// How many of a season's episodes the PC's row shows around the current one.
const _rowWindow = 8;

/// The episodes to show around [current]: up to [count], with it among them.
List<BaseItem> episodesAround(List<BaseItem> episodes, String current, {int count = _rowWindow}) {
  if (episodes.length <= count) return episodes;
  final at = math.max(0, episodes.indexWhere((e) => e.id == current));
  final start = (at - count ~/ 2).clamp(0, episodes.length - count);
  return episodes.sublist(start, start + count);
}

/// Depth's page for an episode.
class DepthEpisodePage extends ConsumerStatefulWidget {
  const DepthEpisodePage({super.key, required this.item});

  final BaseItem item;

  @override
  ConsumerState<DepthEpisodePage> createState() => _DepthEpisodePageState();
}

class _DepthEpisodePageState extends ConsumerState<DepthEpisodePage> with ItemToggles {
  @override
  BaseItem get togglesItem => widget.item;

  bool _hovering = false;

  @override
  void didUpdateWidget(DepthEpisodePage old) {
    super.didUpdateWidget(old);
    if (old.item != widget.item) syncToggles();
  }

  List<BaseItem>? get _episodes {
    final series = widget.item.seriesId;
    if (series == null) return null;
    return ref.watch(episodesProvider((seriesId: series, seasonId: widget.item.seasonId))).value;
  }

  /// Another episode replaces this page, so Back still goes to the series.
  void _open(BaseItem episode) => context.pushReplacement('/item/${episode.id}');

  BaseItem? _next(List<BaseItem>? episodes) {
    if (episodes == null) return null;
    final at = episodes.indexWhere((e) => e.id == widget.item.id);
    return at < 0 || at + 1 >= episodes.length ? null : episodes[at + 1];
  }

  String get _code {
    final item = widget.item;
    return [
      if (item.parentIndexNumber case final s?) s == 0 ? 'Specials' : 'Season $s',
      if (item.indexNumber case final e?) 'Episode $e',
    ].join(' · ');
  }

  String? get _bigNumber => switch (widget.item.indexNumber) {
        final e? => 'E$e',
        _ => null,
      };

  Widget _main({required bool expand}) {
    final item = widget.item;
    final data = toggleData;
    final resumed = data.hasProgress;
    return ResumePill(
      expand: expand,
      autofocus: true,
      label: resumed
          ? 'Resume from ${formatPosition(ticksToDuration(data.playbackPositionTicks))}'
          : (data.played ? 'Play again' : 'Play'),
      detail: resumed && !expand ? timeLeft(item)?.replaceFirst(RegExp('^'), '· ') : null,
      progress: resumed ? watchedFraction(item) : 0,
      onPressed: () => openItem(context, item, play: true),
    );
  }

  Widget _chip({required bool small}) {
    final item = widget.item;
    return Consumer(
      builder: (context, ref, _) {
        final title = preferredAnimeTitle(ref, item, item.seriesName ?? '');
        return Material(
          color: const Color(0xB30A0B12),
          shape: StadiumBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.14))),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => openSeries(context, item),
            child: Padding(
              padding: EdgeInsets.fromLTRB(small ? 4 : 6, small ? 4 : 6, small ? 12 : 14, small ? 4 : 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipOval(
                    child: SizedBox.square(
                      dimension: small ? 22 : 26,
                      child: ItemImage(image: item.posterImage, maxWidth: 26),
                    ),
                  ),
                  SizedBox(width: small ? 7 : 8),
                  Flexible(
                    child: Text(
                      title.isEmpty ? (item.seriesName ?? '') : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: const Color(0xFFE8E9F0), fontSize: small ? 12 : 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final item = widget.item;
    final episodes = _episodes;
    final next = _next(episodes);
    return SmoothWheel(
      builder: (_, wheel) => ListView(
        controller: wheel,
        padding: EdgeInsets.zero,
        children: [
          // The next episode's still, ready before it's opened.
          if (next?.landscapeImage case final still?)
            Offstage(child: SizedBox(width: 480, height: 270, child: ItemImage(image: still, maxWidth: 480))),
          if (phone) _phoneHero(context) else _pcHero(context),
          if (phone) _phoneActions(context),
          _Width(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: phone ? 20 : 88),
                // On a phone it starts just under the buttons, in the first
                // screen: rolling in, it would be missing until scrolled to.
                if (phone) _about(next, episodes) else DrumSection(child: _about(next, episodes)),
                if (phone && next != null) ...[
                  const SizedBox(height: 22),
                  const Kick('Up next'),
                  const SizedBox(height: 10),
                  _UpNextCard(episode: next, onOpen: () => _open(next), small: true),
                ],
              ],
            ),
          ),
          if (episodes != null && episodes.isNotEmpty) _episodeRow(episodes, phone),
          if (item.people.isNotEmpty)
            _Width(
              top: phone ? 14 : 88,
              child: DrumSection(child: DepthCastRow(people: item.people)),
            ),
          SizedBox(height: phone ? 24 : 120),
        ],
      ),
    );
  }

  Widget _pcHero(BuildContext context) {
    final item = widget.item;
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 760;
    final big = narrow ? 150.0 : 250.0;
    final number = _bigNumber;
    return _Width(
      top: 96,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          MouseRegion(
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: Container(
              height: narrow ? 460 : 560,
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
                    image: item.landscapeImage ?? item.backdropImage,
                    maxWidth: width,
                    preview: item,
                    hovering: _hovering,
                    overlay: const _Shade(),
                  ),
                  if (!narrow && _code.isNotEmpty)
                    Positioned(
                      right: 22,
                      top: 26,
                      child: IgnorePointer(
                        child: RotatedBox(
                          quarterTurns: 1,
                          child: Text(
                            _code.toUpperCase(),
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 3.5),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: math.max(24, math.min(56, width * 0.04)),
                    right: narrow ? 24 : 240,
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
                                RiseIn(
                                  delay: 0,
                                  child: Wrap(
                                    spacing: 12,
                                    runSpacing: 8,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [if (item.seriesId != null) _chip(small: false), Kick(_code)],
                                  ),
                                ),
                                const SizedBox(height: 18),
                                _Title(item: item, size: narrow ? 40 : 64),
                                const SizedBox(height: 16),
                                RiseIn(delay: 120, child: _meta(small: false)),
                                const SizedBox(height: 26),
                                RiseIn(
                                  delay: 240,
                                  child: GhostTheme(
                                    child: Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: [
                                        _main(expand: false),
                                        if (toggleData.hasProgress)
                                          GhostButton(
                                            icon: Icons.replay_rounded,
                                            label: 'From start',
                                            onPressed: () => context.push('/play/${item.id}?fromStart=1'),
                                          ),
                                        GhostButton(
                                          icon: toggleData.played ? Icons.check_circle : Icons.check_circle_outline,
                                          label: toggleData.played ? 'Watched' : 'Mark watched',
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
          if (number != null)
            Positioned(right: 28, bottom: -big * 0.21, child: BigNumber(number, size: big)),
        ],
      ),
    );
  }

  Widget _meta({required bool small}) {
    final item = widget.item;
    final cyan = Theme.of(context).colorScheme.secondary;
    return HeroMeta(
      small: small,
      children: [
        if (item.episodeLabel case final code?) Text(code),
        if (item.yearLabel case final year?) Text(year),
        if (item.runtime case final r?) Text(formatRuntime(r)),
        if (item.communityRating case final score?) StarScore(score, small: small),
        if (timeLeft(item) case final left?) Text(left, style: TextStyle(color: cyan)),
      ],
    );
  }

  Widget _phoneHero(BuildContext context) {
    final item = widget.item;
    final number = _bigNumber;
    return SizedBox(
      height: 360 + statusBarHeight(context),
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          HeroPicture(
            image: item.landscapeImage ?? item.backdropImage,
            maxWidth: MediaQuery.sizeOf(context).width,
            hovering: false,
            overlay: const _PhoneShade(),
          ),
          if (number != null) Positioned(right: 8, top: 120 + statusBarHeight(context), child: BigNumber(number, size: 96)),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.seriesId != null) _chip(small: true),
                const SizedBox(height: 10),
                RiseIn(delay: 0, child: Kick(_code)),
                const SizedBox(height: 6),
                _Title(item: item, size: 32),
                const SizedBox(height: 8),
                RiseIn(delay: 120, child: _meta(small: true)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _phoneActions(BuildContext context) {
    final item = widget.item;
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
                  label: 'From start',
                  icon: Icons.replay_rounded,
                  onPressed: () => context.push('/play/${item.id}?fromStart=1'),
                ),
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
                if (canDownload(item)) RoundAction(label: 'Download', child: EpisodeDownloadButton(episode: item)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _about(BaseItem? next, List<BaseItem>? episodes) {
    final item = widget.item;
    final phone = context.layout.formFactor == FormFactor.phone;
    final overview = item.overview ?? '';
    final about = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Kick('About this episode'),
        if (overview.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: phone ? 8 : 14),
            child: DepthOverview(text: overview, lines: 8),
          ),
        if (item.genres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final genre in item.genres)
                  DetailChip(genre, onPressed: () => context.push('/genre/${Uri.encodeComponent(genre)}')),
              ],
            ),
          ),
        MalPanel(item: item, columns: 4),
      ],
    );
    if (phone) return about;
    final seasonName = item.seasonName ?? 'Season';
    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (next != null) ...[
          const Kick('Up next'),
          const SizedBox(height: 14),
          _UpNextCard(episode: next, onOpen: () => _open(next)),
          const SizedBox(height: 16),
        ],
        if (episodes != null && episodes.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF0C0E15),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$seasonName progress',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFF9AA0B2), fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(SeasonStrip.countOf(episodes), style: const TextStyle(color: Color(0xFFE8E9F0), fontSize: 13, fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 12),
                SeasonStrip(episodes: episodes),
              ],
            ),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < detailOneColumnBelow - 100) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [about, const SizedBox(height: 32), side],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 7, child: about),
            const SizedBox(width: 40),
            Expanded(flex: 4, child: side),
          ],
        );
      },
    );
  }

  Widget _episodeRow(List<BaseItem> episodes, bool phone) {
    final item = widget.item;
    final kick = [
      item.seasonName ?? 'Season',
      '${episodes.where((e) => !e.isVirtual).length} episodes',
    ].join(' · ');
    if (phone) {
      return Padding(
        padding: const EdgeInsets.only(top: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: SectionHeading(kick: kick, title: 'More episodes')),
            const SizedBox(height: 8),
            _MoreEpisodes(episodes: episodes, current: item.id, onOpen: _open),
          ],
        ),
      );
    }
    final side = (MediaQuery.sizeOf(context).width * 0.034).clamp(16.0, 44.0);
    return Padding(
      padding: const EdgeInsets.only(top: 88),
      child: Center(
        child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1400),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExpandingRow(
            kicker: kick,
            gutter: side,
            topGap: 0,
            currentId: item.id,
            actionLabel: (e) => e.userData.hasProgress ? 'Resume' : 'Play',
            data: LibraryRowData(
              title: 'Episodes',
              items: AsyncData(episodesAround(episodes, item.id)),
              onItemPressed: (e) => e.id == item.id ? null : _open(e),
            ),
          ),
          if (episodes.length > _rowWindow && item.seriesId != null)
            Padding(
              padding: EdgeInsets.only(top: 8, right: side),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => openSeries(context, item), child: const Text('All episodes')),
              ),
            ),
        ],
      ),
        ),
      ),
    );
  }
}

/// The episode page's width and margins.
class _Width extends StatelessWidget {
  const _Width({required this.child, this.top = 0});

  final Widget child;
  final double top;

  @override
  Widget build(BuildContext context) {
    final phone = context.layout.formFactor == FormFactor.phone;
    final side = phone ? 16.0 : (MediaQuery.sizeOf(context).width * 0.034).clamp(16.0, 44.0);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: Padding(padding: EdgeInsets.fromLTRB(side, top, side, 0), child: child),
      ),
    );
  }
}

class _Title extends ConsumerWidget {
  const _Title({required this.item, required this.size});

  final BaseItem item;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TrackingTitle(
        preferredEpisodeTitle(ref, item, item.name),
        style: (Theme.of(context).textTheme.displaySmall ?? const TextStyle()).copyWith(
          fontSize: size,
          fontWeight: FontWeight.w800,
          height: 1.02,
          color: Colors.white,
          letterSpacing: -size * 0.02,
        ),
      );
}

class _Shade extends StatelessWidget {
  const _Shade();

  @override
  Widget build(BuildContext context) => const Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                stops: [0, 0.42, 0.75],
                colors: [Color(0xEB06070B), Color(0x8C06070B), Color(0x0D06070B)],
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

/// The next episode: the card opens it, the button plays it.
class _UpNextCard extends StatefulWidget {
  const _UpNextCard({required this.episode, required this.onOpen, this.small = false});

  final BaseItem episode;
  final VoidCallback onOpen;
  final bool small;

  @override
  State<_UpNextCard> createState() => _UpNextCardState();
}

class _UpNextCardState extends State<_UpNextCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final small = widget.small;
    final cyan = Theme.of(context).colorScheme.secondary;
    final code = [?episode.episodeLabel, if (episode.runtime case final r?) formatRuntime(r)].join(' · ');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(small ? 18 : 22),
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedScale(
                  scale: _hover ? 1.07 : 1,
                  duration: const Duration(seconds: 1),
                  curve: const Cubic(0.2, 0.7, 0.2, 1),
                  child: ItemImage(image: episode.landscapeImage ?? episode.posterImage, maxWidth: 480),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      stops: [0, 0.65],
                      colors: [Color(0xEB06070B), Color(0x0006070B)],
                    ),
                  ),
                ),
                Positioned(
                  left: small ? 14 : 18,
                  right: small ? 64 : 76,
                  bottom: small ? 12 : 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(code, style: TextStyle(color: cyan, fontSize: small ? 11 : 12, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Consumer(
                        builder: (context, ref, _) => Text(
                          preferredEpisodeTitle(ref, episode, episode.name),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(
                            color: Colors.white,
                            fontSize: small ? 18 : 22,
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: small ? 12 : 16,
                  bottom: small ? 12 : 16,
                  child: AnimatedScale(
                    scale: _hover ? 1.12 : 1,
                    duration: const Duration(milliseconds: 400),
                    child: SizedBox.square(
                      dimension: small ? 40 : 46,
                      child: IconButton(
                        tooltip: 'Play ${episode.name}',
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(backgroundColor: const Color(0xFFF2F0FF), foregroundColor: const Color(0xFF0B0C12)),
                        onPressed: () => openItem(context, episode, play: true),
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                    ),
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

/// A phone's swipe row of the season's episodes, this one outlined and in view.
class _MoreEpisodes extends StatefulWidget {
  const _MoreEpisodes({required this.episodes, required this.current, required this.onOpen});

  final List<BaseItem> episodes;
  final String current;
  final ValueChanged<BaseItem> onOpen;

  @override
  State<_MoreEpisodes> createState() => _MoreEpisodesState();
}

class _MoreEpisodesState extends State<_MoreEpisodes> {
  static const _width = 164.0;
  static const _gap = 10.0;

  late final _scroll = ScrollController(
    initialScrollOffset: math.max(0, widget.episodes.indexWhere((e) => e.id == widget.current)) * (_width + _gap),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cyan = Theme.of(context).colorScheme.secondary;
    return SizedBox(
      height: 146,
      child: SideScroll(
        builder: (controller) => ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: widget.episodes.length,
          separatorBuilder: (_, _) => const SizedBox(width: _gap),
          itemBuilder: (context, i) {
            final episode = widget.episodes[i];
            final current = episode.id == widget.current;
            return SizedBox(
              width: _width,
              child: Material(
                color: const Color(0xFF0E1018),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: current ? const Color(0xFF8F84FF) : Colors.white.withValues(alpha: 0.08),
                    width: current ? 1.5 : 1,
                  ),
                ),
                child: InkWell(
                  onTap: current ? null : () => widget.onOpen(episode),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: 86, width: _width, child: EpisodeThumb(episode: episode, width: _width)),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(episode.episodeLabel ?? '', style: TextStyle(color: cyan, fontSize: 10, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 2),
                            Text(
                              episode.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
