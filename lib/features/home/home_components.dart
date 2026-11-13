import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/layout.dart';
import '../../app/card_look.dart';
import '../../core/jellyfin/items.dart';
import '../../core/seerr/seerr_api.dart';
import '../../theme/components.dart';
import '../library/widgets/card_actions.dart';
import '../library/widgets/media_card.dart';
import '../library/widgets/media_row.dart';
import '../seerr/widgets/seerr_widgets.dart';
import 'depth/depth_top_bar.dart';
import 'depth/drum_section.dart';
import 'depth/expanding_row.dart';
import 'depth/genre_tiles.dart';
import 'depth/library_doors.dart';
import 'depth/next_shelf.dart';
import 'depth/resume_stage.dart';
import 'depth/week_timeline.dart';
import 'home_header.dart';
import 'home_tabs.dart';
import 'this_week.dart';

/// What a row of library items shows, for any style of row.
class LibraryRowData {
  const LibraryRowData({
    required this.title,
    required this.items,
    required this.onItemPressed,
    this.shape = CardShape.poster,
    this.cardRow,
    this.onTitlePressed,
    this.onItemTitlePressed,
    this.onItemSubtitlePressed,
    this.look,
  });

  final String title;
  final AsyncValue<List<BaseItem>> items;
  final CardShape shape;

  /// Which row it is, for the cards' menus (Continue watching, Next up).
  final CardRow? cardRow;
  final void Function(BaseItem item) onItemPressed;
  final VoidCallback? onTitlePressed;
  final void Function(BaseItem item)? onItemTitlePressed;
  final void Function(BaseItem item)? onItemSubtitlePressed;

  /// A custom row's chosen look ("shelf", "expanding"), for styles that
  /// follow it.
  final String? look;
}

/// What Browse by genre shows.
class GenreRowData {
  const GenreRowData({required this.title, required this.genres, required this.onGenrePressed});

  final String title;
  final AsyncValue<List<String>> genres;
  final void Function(String genre) onGenrePressed;
}

/// What a row of Seerr titles shows.
class SeerrRowData {
  const SeerrRowData({required this.title, required this.items, this.subtitle});

  final String title;
  final AsyncValue<List<SeerrMedia>> items;
  final String? subtitle;
}

/// One of Home's tools (search, downloads, settings…), for any style of top
/// bar to draw: icon buttons (Classic), a fold-out pill (Depth)…
class HomeAction {
  const HomeAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.shortcut,
    this.pinned = false,
  });

  final String label;
  final Widget icon;
  final VoidCallback onPressed;

  /// Shown with the label (e.g. "F5").
  final String? shortcut;

  /// Stays in view when there isn't room for every tool; the others fold
  /// into a menu.
  final bool pinned;

  String get tooltip => shortcut == null ? label : '$label ($shortcut)';
}

/// Home's top bar: the server, and the tools.
class HomeTopBarData {
  const HomeTopBarData({
    required this.serverName,
    required this.host,
    required this.actions,
    required this.title,
    this.tab,
    this.onTab,
    this.leading,
    this.scrolled,
    this.tabs = HomeTab.values,
    this.extras = const [],
  });

  /// The tabs shown, and what's been added after them.
  final List<HomeTab> tabs;
  final List<HomeAction> extras;

  /// Before the brand (a page's Back button).
  final Widget? leading;

  /// How far the page under the bar has scrolled, if it isn't Home.
  final ValueListenable<double>? scrolled;

  final String serverName;
  final String host;
  final List<HomeAction> actions;

  /// The server's name as Classic shows it.
  final Widget title;

  /// The tab showing, and moving to another (a bar that has tabs).
  final HomeTab? tab;
  final ValueChanged<HomeTab>? onTab;
}

/// The styles each part of Home can be drawn in, by slot. Classic is the
/// look the app has always had; a theme picks another by name.
abstract final class HomeComponents {
  static Widget _mediaRow(BuildContext context, LibraryRowData d, ComponentStyle style) => MediaRow(
        title: d.title,
        items: d.items,
        shape: d.shape,
        cardRow: d.cardRow,
        onItemPressed: d.onItemPressed,
        onTitlePressed: d.onTitlePressed,
        onItemTitlePressed: d.onItemTitlePressed,
        onItemSubtitlePressed: d.onItemSubtitlePressed,
      );

  /// "tiles": poster tiles that lift and tilt (Depth), with an optional
  /// `kicker` line above the title.
  static Widget _tiles(BuildContext context, ComponentStyle style, Widget row) =>
      CardLook(tiles: true, kicker: style.param<String?>('kicker', null), child: row);

  /// Rows of library items, one registry per kind of row (a theme can style
  /// Continue watching differently from Recently added).
  static final libraryRows = {
    for (final slot in [Slots.continueWatching, Slots.nextUp, Slots.libraries, Slots.recentlyAdded, Slots.libraryRow])
      slot: Variants<LibraryRowData>(slot, classic: _mediaRow)
        ..register('tiles', (context, d, style) => _tiles(context, style, _mediaRow(context, d, style)))
        // A list beside a large stage, see [ResumeStage] (Depth's Continue watching).
        ..register('stage', (context, d, style) => ResumeStage(data: d))
        // Spines that open into covers, see [ShelfRow] (Depth's Next up).
        ..register('shelf', (context, d, style) => ShelfRow(data: d, kicker: style.param<String?>('kicker', null)))
        ..register('expanding', (context, d, style) => ExpandingRow(data: d, kicker: style.param<String?>('kicker', null)))
        // A door for each library, see [LibraryDoors] (Depth's Libraries).
        ..register('doors', (context, d, style) => LibraryDoors(data: d, kicker: style.param<String?>('kicker', null)))
        // Each custom row's own choice: shelf or expanding.
        ..register(
          'byRow',
          (context, d, style) => d.look == 'expanding'
              ? ExpandingRow(data: d, kicker: style.param<String?>('kicker', null))
              : ShelfRow(data: d, kicker: style.param<String?>('kicker', null)),
        ),
  };

  static final seerrRows = Variants<SeerrRowData>(Slots.seerrRow, classic: _seerrRow)
    ..register('tiles', (context, d, style) => _tiles(context, style, _seerrRow(context, d, style)));

  /// This week. "timeline" (Depth): days on a line, see [WeekTimeline].
  static final weekRows = Variants<WeekRowData>(Slots.thisWeek, classic: (context, d, style) => WeekRow(data: d))
    ..register('timeline', (context, d, style) => WeekTimeline(data: d, kicker: style.param<String?>('kicker', null)));

  /// Browse by genre. Classic: a row of chips. "flips" (Depth): [GenreTiles].
  static final genreRows = Variants<GenreRowData>(Slots.genres, classic: _genreChips)
    ..register('flips', (context, d, style) => GenreTiles(data: d, kicker: style.param<String?>('kicker', null)));

  static Widget _genreChips(BuildContext context, GenreRowData d, ComponentStyle style) {
    final genres = d.genres.value ?? const <String>[];
    if (genres.isEmpty) return const SizedBox.shrink();
    final gutter = context.layout.gutter;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 24, gutter, 8),
          child: Text(d.title, style: Theme.of(context).textTheme.titleLarge),
        ),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: gutter),
            itemCount: genres.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => ActionChip(
              label: Text(genres[i]),
              onPressed: () => d.onGenrePressed(genres[i]),
            ),
          ),
        ),
      ],
    );
  }

  /// Around each section of Home. Classic: nothing. "drum" (Depth): see
  /// [DrumSection].
  static final sections = Variants<Widget>(Slots.homeSection, classic: (context, child, style) => child)
    ..register('drum', (context, child, style) => DrumSection(child: child));

  static Widget _seerrRow(BuildContext context, SeerrRowData d, ComponentStyle style) =>
      SeerrMediaRow(title: d.title, subtitle: d.subtitle, items: d.items);

  /// The big picture at the top of Home (Settings > Home > Header).
  /// "deck" (Depth on phones and TVs): the featured shows as a deck of
  /// panels; "programme" (Depth on a PC): a numbered list and one frame.
  static final hero = Variants<void>(Slots.homeHero, classic: (context, _, style) => const HomeHeader())
    ..register('deck', (context, _, style) => HomeHeader(style: style))
    ..register('programme', (context, _, style) => HomeHeader(style: style));

  /// How far Home has scrolled (top bars that fold away, the header's
  /// see-through bar).
  static final scrolled = ValueNotifier<double>(0);

  /// The top bar's tools, Classic: a row of icon buttons in the app bar.
  /// Where they don't all fit (a phone), the pinned ones stay and the rest
  /// fold into a "More" menu.
  /// "pill" (Depth): the whole bar, see [PillTopBar].
  static final topBarActions = Variants<HomeTopBarData>(Slots.homeTopBar, classic: _classicTopBar)
    ..register('pill', (context, d, style) => PillTopBar(data: d, style: style, scrolled: d.scrolled ?? scrolled));

  /// Styles that draw the whole bar themselves, not just the tools.
  static bool fillsBar(ComponentStyle style) =>
      style.variant != 'classic' && topBarActions.names.contains(style.variant);

  /// Room kept for the server's name, and one icon button's width.
  static const _titleRoom = 150.0;
  static const _buttonWidth = 48.0;
  static const _tabHalf = 55.0;

  static Widget _classicTopBar(BuildContext context, HomeTopBarData d, ComponentStyle style) {
    Widget button(HomeAction a) => IconButton(tooltip: a.tooltip, icon: a.icon, onPressed: a.onPressed);
    final width = MediaQuery.sizeOf(context).width;
    // Tabs in the true centre leave the right half, less their half.
    final count = d.tabs.length + d.extras.length;
    final centred = d.tab != null && count > 1 && context.layout.formFactor != FormFactor.phone;
    final fits = (centred ? width / 2 - count * _tabHalf - 10 : width - _titleRoom) ~/ _buttonWidth;
    if (d.actions.length <= fits) {
      return Row(mainAxisSize: MainAxisSize.min, children: [for (final a in d.actions) button(a)]);
    }
    final folded = [for (final a in d.actions) if (!a.pinned) a];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final a in d.actions)
          if (a.pinned) button(a),
        if (folded.isNotEmpty)
        PopupMenuButton<HomeAction>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert),
          onSelected: (a) => a.onPressed(),
          itemBuilder: (context) => [
            for (final a in folded)
              PopupMenuItem(
                value: a,
                child: Row(
                  children: [
                    IconTheme.merge(data: const IconThemeData(size: 22), child: a.icon),
                    const SizedBox(width: 14),
                    Text(a.label),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// [slot]'s row of library items, in the active theme's style.
Widget libraryRow(BuildContext context, WidgetRef ref, String slot, LibraryRowData data) =>
    HomeComponents.libraryRows[slot]!.build(context, data, ref.watch(componentStyleProvider(slot)));

/// This week, in the active theme's style.
Widget weekRow(BuildContext context, WidgetRef ref, WeekRowData data) =>
    HomeComponents.weekRows.build(context, data, ref.watch(componentStyleProvider(Slots.thisWeek)));

/// Browse by genre, in the active theme's style.
Widget genreRow(BuildContext context, WidgetRef ref, GenreRowData data) =>
    HomeComponents.genreRows.build(context, data, ref.watch(componentStyleProvider(Slots.genres)));

/// A section of Home, in the active theme's style.
Widget homeSection(BuildContext context, WidgetRef ref, Widget child) =>
    HomeComponents.sections.build(context, child, ref.watch(componentStyleProvider(Slots.homeSection)));

/// A row of Seerr titles, in the active theme's style.
Widget seerrRow(BuildContext context, WidgetRef ref, SeerrRowData data) =>
    HomeComponents.seerrRows.build(context, data, ref.watch(componentStyleProvider(Slots.seerrRow)));
