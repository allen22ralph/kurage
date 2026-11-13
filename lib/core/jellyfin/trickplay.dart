import 'items.dart';

/// Jellyfin's trickplay (seek preview) images for one media source: tile
/// sheets of [tileWidth] × [tileHeight] thumbnails, one every [interval].
class Trickplay {
  const Trickplay({
    required this.mediaSourceId,
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileHeight,
    required this.count,
    required this.interval,
  });

  final String mediaSourceId;

  /// One thumbnail's size, in pixels.
  final int width;
  final int height;
  final int tileWidth;
  final int tileHeight;
  final int count;
  final Duration interval;

  int get perTile => tileWidth * tileHeight;

  /// The trickplay set of [item] for [mediaSourceId] (else its first),
  /// the resolution nearest [preferredWidth]; null when there is none.
  static Trickplay? of(BaseItem item, {String? mediaSourceId, int preferredWidth = 320}) {
    final all = item.raw['Trickplay'];
    if (all is! Map || all.isEmpty) return null;
    final sourceId = all.containsKey(mediaSourceId) ? mediaSourceId! : all.keys.first as String;
    final sizes = all[sourceId];
    if (sizes is! Map || sizes.isEmpty) return null;
    final options = [
      for (final e in sizes.entries)
        if (e.value case final Map v)
          if ((v['Width'] as num?)?.toInt() case final w? when w > 0)
            Trickplay(
              mediaSourceId: sourceId,
              width: w,
              height: (v['Height'] as num?)?.toInt() ?? w * 9 ~/ 16,
              tileWidth: (v['TileWidth'] as num?)?.toInt() ?? 10,
              tileHeight: (v['TileHeight'] as num?)?.toInt() ?? 10,
              count: (v['ThumbnailCount'] as num?)?.toInt() ?? 0,
              interval: Duration(milliseconds: (v['Interval'] as num?)?.toInt() ?? 10000),
            ),
    ]..removeWhere((t) => t.count == 0);
    if (options.isEmpty) return null;
    options.sort((a, b) => (a.width - preferredWidth).abs().compareTo((b.width - preferredWidth).abs()));
    return options.first._coveringAtLeast(item.runtime);
  }

  /// The server's count can be far too low (2 for a whole episode,
  /// whose sheets are all there), which held every time on one frame. The
  /// frames the file's length needs count too, so the bar follows the time.
  Trickplay _coveringAtLeast(Duration? length) {
    if (length == null || interval <= Duration.zero) return this;
    final needed = (length.inMilliseconds / interval.inMilliseconds).ceil();
    if (needed <= count) return this;
    return Trickplay(
      mediaSourceId: mediaSourceId,
      width: width,
      height: height,
      tileWidth: tileWidth,
      tileHeight: tileHeight,
      count: needed,
      interval: interval,
    );
  }

  /// Which tile sheet, and which cell in it, shows the frame at [time].
  ({int tile, int column, int row}) frameAt(Duration time) {
    final index = (time.inMilliseconds ~/ interval.inMilliseconds).clamp(0, count - 1);
    final within = index % perTile;
    return (tile: index ~/ perTile, column: within % tileWidth, row: within ~/ tileWidth);
  }

  /// A tile sheet's address (`api_key` so it loads like any image).
  Uri tileUrl(Uri server, String itemId, int tile, String token) {
    final base = server.path.endsWith('/') ? server.path : '${server.path}/';
    return server.replace(
      path: '${base}Videos/$itemId/Trickplay/$width/$tile.jpg',
      queryParameters: {'mediaSourceId': mediaSourceId, 'api_key': token},
    );
  }
}
