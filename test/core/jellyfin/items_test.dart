import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';

void main() {
  test('parses an episode with series fallbacks for images', () {
    final item = BaseItem.fromJson({
      'Id': 'ep1',
      'Name': 'The Journey Begins',
      'Type': 'Episode',
      'SeriesId': 'ser1',
      'SeriesName': 'Frieren',
      'IndexNumber': 3,
      'ParentIndexNumber': 1,
      'RunTimeTicks': 24 * 60 * ticksPerSecond,
      'ImageTags': <String, Object>{},
      'SeriesPrimaryImageTag': 'sp',
      'ParentBackdropItemId': 'ser1',
      'ParentBackdropImageTags': ['bd'],
      'ProviderIds': {'AniDB': '17617', 'Tvdb': 424536},
      'UserData': {
        'PlaybackPositionTicks': 600 * ticksPerSecond,
        'PlayedPercentage': 41.6,
        'Played': false,
        'IsFavorite': true,
      },
    });

    expect(item.type, ItemType.episode);
    expect(item.episodeLabel, 'S1:E3');
    expect(item.runtime, const Duration(minutes: 24));
    expect(item.posterImage?.itemId, 'ser1');
    expect(item.posterImage?.tag, 'sp');
    // No episode still: falls back to the series backdrop.
    expect(item.landscapeImage?.type, 'Backdrop');
    expect(item.landscapeImage?.itemId, 'ser1');
    expect(item.providerIds, {'AniDB': '17617', 'Tvdb': '424536'});
    expect(item.userData.hasProgress, isTrue);
    expect(item.userData.isFavorite, isTrue);
  });

  test('year label for series reflects airing status', () {
    BaseItem series(Map<String, Object?> extra) => BaseItem.fromJson({
          'Id': 's',
          'Name': 'Show',
          'Type': 'Series',
          'ProductionYear': 2019,
          ...extra,
        });

    expect(series({'Status': 'Continuing'}).yearLabel, '2019–');
    expect(
      series({'Status': 'Ended', 'EndDate': '2023-03-01T00:00:00Z'}).yearLabel,
      '2019–2023',
    );
    expect(series({'Status': 'Ended'}).yearLabel, '2019');
  });

  test('marking played clears progress', () {
    const data = UserItemData(
      playbackPositionTicks: 100,
      playedPercentage: 50,
      unplayedItemCount: 4,
    );
    final played = data.copyWith(played: true);
    expect(played.played, isTrue);
    expect(played.hasProgress, isFalse);
    expect(played.unplayedItemCount, 0);
  });

  test('ticks conversions round-trip', () {
    const d = Duration(minutes: 23, seconds: 41, milliseconds: 500);
    expect(ticksToDuration(durationToTicks(d)), d);
  });

  test('overviews lose their HTML', () {
    expect(
      htmlToPlainText('He can rewind death.<br>Source: ANN'),
      'He can rewind death.\nSource: ANN',
    );
    expect(
      htmlToPlainText('<p>Part one.</p><p>Tom &amp; Jerry &quot;meet&quot;&#33;</p>'),
      'Part one.\n\nTom & Jerry "meet"!',
    );
    expect(htmlToPlainText('<i>Plain</i> <br/>text'), 'Plain \ntext');
    final item = BaseItem.fromJson({'Id': 'x', 'Name': 'X', 'Type': 'Series', 'Overview': 'A<br />B'});
    expect(item.overview, 'A\nB');
  });
}
