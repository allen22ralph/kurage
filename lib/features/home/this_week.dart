import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/layout.dart';
import '../../app/providers.dart';
import '../../app/toast.dart';
import '../../core/jellyfin/items.dart';
import '../../core/jellyfin/week_api.dart';
import '../library/navigation.dart';
import '../library/widgets/item_image.dart';

final weekApiProvider = Provider<WeekApi>((ref) {
  final api = ref.watch(signedInApiProvider);
  return WeekApi(api, userId: ref.watch(currentSessionProvider).userId);
});

/// Where This week comes from (Settings > Home).
final weekSourceChoiceProvider = AsyncNotifierProvider<WeekSourceChoiceController, WeekSourceChoice>(
  WeekSourceChoiceController.new,
);

class WeekSourceChoiceController extends AsyncNotifier<WeekSourceChoice> {
  static const _key = 'home.thisWeek.source';

  @override
  Future<WeekSourceChoice> build() async =>
      WeekSourceChoice.fromName((await SharedPreferences.getInstance()).getString(_key));

  Future<void> save(WeekSourceChoice choice) async {
    state = AsyncData(choice);
    await (await SharedPreferences.getInstance()).setString(_key, choice.name);
  }
}

/// This week (Monday to Sunday): Sonarr and Radarr's calendar through the
/// server's Jellyfin Enhanced plugin, else Jellyfin's own, as chosen.
final thisWeekProvider = FutureProvider<WeekSchedule>(
  (ref) async {
    final choice = await ref.watch(weekSourceChoiceProvider.future);
    return ref.watch(weekApiProvider).week(weekStart(DateTime.now()), choice: choice);
  },
  // Not retried by itself (it's no more than a row): Home's Refresh, or the
  // next start, asks again.
  retry: (_, _) => null,
);

/// What a This week row shows.
class WeekRowData {
  const WeekRowData({required this.title, required this.week});

  final String title;
  final AsyncValue<WeekSchedule> week;
}

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Where [week] came from and why, for Settings > Home: "Showing Jellyfin
/// (Sonarr and Radarr have nothing this week)".
String weekSourceStatus(WeekSchedule week) {
  final why = week.note;
  if (week.failed) return 'Not available: $why';
  final trouble = week.problems.length;
  return switch (week.source) {
    WeekSource.arr when why != null => 'Showing Sonarr / Radarr: $why',
    WeekSource.arr when trouble > 0 => "Showing Sonarr / Radarr, except $trouble the server couldn't reach",
    WeekSource.arr => 'Showing Sonarr / Radarr, through your server',
    WeekSource.jellyfin when why != null => 'Showing Jellyfin ($why)',
    WeekSource.jellyfin => 'Showing Jellyfin',
  };
}

/// The row when Sonarr and Radarr were asked for alone and can't answer.
class WeekUnavailable extends StatelessWidget {
  const WeekUnavailable({super.key, required this.title, required this.week});

  final String title;
  final WeekSchedule week;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = context.layout.gutter;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 24, gutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            "Sonarr and Radarr aren't available: ${week.note}.",
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// The row in place of nothing at all: asked and unavailable, with no entries
/// to show instead.
bool weekShowsUnavailable(WeekSchedule week) => week.failed || (week.entries.isEmpty && week.rowNote != null);

/// A small line under a This week heading, when the row isn't showing all it
/// should ([WeekSchedule.rowNote]).
class WeekNote extends StatelessWidget {
  const WeekNote({super.key, required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(note, style: theme.textTheme.bodySmall?.copyWith(color: color))),
        ],
      ),
    );
  }
}

/// Whether coming back to the app should ask again: soon when Sonarr or Radarr
/// were out of reach (they may be back), otherwise when the list has aged. Not
/// every time, as a PC "comes back" with each change of window.
bool weekNeedsRefresh(WeekSchedule? week, Duration sinceAsked) {
  final trouble = week == null || week.troubled;
  return sinceAsked >= (trouble ? const Duration(minutes: 1) : const Duration(minutes: 30));
}

/// Keeps This week current without Home's Refresh: asks again on coming back to
/// the app, see [weekNeedsRefresh].
class WeekRefresher extends ConsumerStatefulWidget {
  const WeekRefresher({super.key, required this.child, this.now = DateTime.now});

  final Widget child;
  final DateTime Function() now;

  @override
  ConsumerState<WeekRefresher> createState() => _WeekRefresherState();
}

class _WeekRefresherState extends ConsumerState<WeekRefresher> {
  late DateTime _asked = widget.now();
  late final _lifecycle = AppLifecycleListener(onResume: _check);

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  void _check() {
    final now = widget.now();
    if (!weekNeedsRefresh(ref.read(thisWeekProvider).value, now.difference(_asked))) return;
    _asked = now;
    ref.invalidate(thisWeekProvider);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Home's Refresh asks too; the wait starts over from then.
    ref.listen(thisWeekProvider, (previous, next) {
      if (next.isLoading) _asked = widget.now();
    });
    return widget.child;
  }
}

/// "Today", "Tomorrow", else the day's short name.
String weekDayLabel(DateTime day, {DateTime? now}) {
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final d = DateUtils.dateOnly(day);
  if (d == today) return 'Today';
  if (d == today.add(const Duration(days: 1))) return 'Tomorrow';
  return _days[d.weekday - 1];
}

/// A day list's title: "Today · Wed, Nov 4", or just "Fri, Nov 6", as [date]
/// already names the day.
String weekDayTitle(DateTime day, String date, {DateTime? now}) {
  final label = weekDayLabel(day, now: now);
  return label == 'Today' || label == 'Tomorrow' ? '$label · $date' : date;
}

/// "21:30"; nothing for a date without a time (Jellyfin's).
String? weekTime(BuildContext context, WeekEntry e) {
  if (e.at.hour == 0 && e.at.minute == 0) return null;
  return MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay.fromDateTime(e.at), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
}

/// Where it stands: in the library, airing at a time, or aired and not in.
String weekStatus(BuildContext context, WeekEntry e, {DateTime? now}) {
  if (e.inLibrary) return 'In your library';
  final time = weekTime(context, e);
  final passed = e.at.isBefore(now ?? DateTime.now());
  if (e.movie) return e.release ?? 'Release';
  if (passed) return 'Aired · not in yet';
  return time == null ? 'Airs' : 'Airs $time';
}

/// Opens [e]: the episode or film when it's in, else its show; nothing to
/// open when Jellyfin doesn't have it at all.
void openWeekEntry(BuildContext context, WeekEntry e) {
  final item = e.item;
  if (item == null) {
    showToast("${e.title} isn't in your library yet.");
    return;
  }
  if (item.type == ItemType.episode && item.isVirtual) return openSeries(context, item);
  if (item.type == ItemType.episode) return openEpisode(context, item);
  openItem(context, item);
}

/// [e]'s picture: its episode still or show art from Jellyfin, else
/// Sonarr/Radarr's.
class WeekImage extends StatelessWidget {
  const WeekImage({super.key, required this.entry, required this.width});

  final WeekEntry entry;
  final double width;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final image = item?.landscapeImage ?? item?.backdropImage ?? item?.posterImage;
    if (image != null) return ItemImage(image: image, maxWidth: width);
    if (entry.imageUrl case final url?) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        memCacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
        errorWidget: (_, _, _) => const _NoImage(),
      );
    }
    return const _NoImage();
  }
}

class _NoImage extends StatelessWidget {
  const _NoImage();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF16182A),
    child: Center(child: Icon(Icons.live_tv_outlined, color: Colors.white.withValues(alpha: 0.25))),
  );
}

/// A day's whole list (more than one card shows).
Future<void> showWeekDay(BuildContext context, DateTime day, List<WeekEntry> entries) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheet) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.75),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              weekDayTitle(day, MaterialLocalizations.of(sheet).formatMediumDate(day)),
              style: Theme.of(sheet).textTheme.titleMedium,
            ),
          ),
          for (final e in entries)
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(width: 96, height: 54, child: WeekImage(entry: e, width: 96)),
              ),
              title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [?e.code, ?e.episodeTitle, weekStatus(sheet, e)].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.pop(sheet);
                openWeekEntry(context, e);
              },
            ),
        ],
      ),
    ),
  ),
);

/// Classic's This week: a row of cards in order, each with its day and
/// time, starting at today.
class WeekRow extends StatefulWidget {
  const WeekRow({super.key, required this.data});

  final WeekRowData data;

  @override
  State<WeekRow> createState() => _WeekRowState();
}

class _WeekRowState extends State<WeekRow> {
  ScrollController? _scroll;

  static const _width = 240.0;
  static const _gap = 16.0;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final week = widget.data.week.value;
    if (week != null && weekShowsUnavailable(week)) return WeekUnavailable(title: widget.data.title, week: week);
    if (week == null || week.entries.isEmpty) return const SizedBox.shrink();
    final layout = context.layout;
    final entries = week.entries;
    // Starting at today's first (the week's earlier days to the left).
    final today = DateUtils.dateOnly(DateTime.now());
    final first = entries.indexWhere((e) => !e.at.isBefore(today));
    _scroll ??= ScrollController(initialScrollOffset: first <= 0 ? 0 : first * (_width + _gap));
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(layout.gutter, 24, layout.gutter, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.data.title, style: theme.textTheme.titleLarge),
              if (week.rowNote case final note?) WeekNote(note: note),
            ],
          ),
        ),
        SizedBox(
          height: _width * 9 / 16 + 96,
          child: ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(layout.gutter, 8, layout.gutter, 8),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: _gap),
            itemBuilder: (context, i) {
              final e = entries[i];
              return SizedBox(
                width: _width,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => openWeekEntry(context, e),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [weekDayLabel(e.at), ?weekTime(context, e)].join(' · ').toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: WeekImage(entry: e, width: _width),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                      Text(
                        [?e.code, weekStatus(context, e)].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
