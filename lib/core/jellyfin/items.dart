/// Media item models (`BaseItemDto` on the server) and related types.
///
/// Only the fields the client uses are parsed; [raw] keeps the full JSON
/// for features that need more later (e.g. provider IDs for MAL matching).
library;

/// 100-nanosecond ticks, the unit Jellyfin uses for all durations.
const ticksPerSecond = 10000000;

Duration ticksToDuration(int ticks) =>
    Duration(microseconds: ticks ~/ 10);

int durationToTicks(Duration duration) => duration.inMicroseconds * 10;

/// Item types the client treats specially. Anything else is [other].
enum ItemType {
  movie('Movie'),
  series('Series'),
  season('Season'),
  episode('Episode'),
  boxSet('BoxSet'),
  playlist('Playlist'),
  folder('Folder'),
  collectionFolder('CollectionFolder'),
  userView('UserView'),
  person('Person'),
  musicAlbum('MusicAlbum'),
  audio('Audio'),
  video('Video'),
  other('');

  const ItemType(this.apiName);

  final String apiName;

  static ItemType parse(String? name) => ItemType.values.firstWhere(
        (t) => t.apiName == name,
        orElse: () => ItemType.other,
      );

  /// Whether items of this type play directly rather than opening a list.
  bool get isPlayable =>
      this == movie || this == episode || this == video || this == audio;
}

/// Per-user state for an item: progress, watched, favorite.
class UserItemData {
  const UserItemData({
    this.playbackPositionTicks = 0,
    this.playedPercentage,
    this.played = false,
    this.isFavorite = false,
    this.unplayedItemCount,
    this.likes = false,
  });

  factory UserItemData.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const UserItemData();
    return UserItemData(
      playbackPositionTicks: (json['PlaybackPositionTicks'] as num?)?.toInt() ?? 0,
      playedPercentage: (json['PlayedPercentage'] as num?)?.toDouble(),
      played: json['Played'] as bool? ?? false,
      isFavorite: json['IsFavorite'] as bool? ?? false,
      unplayedItemCount: (json['UnplayedItemCount'] as num?)?.toInt(),
      likes: json['Likes'] as bool? ?? false,
    );
  }

  final int playbackPositionTicks;
  final double? playedPercentage;
  final bool played;
  final bool isFavorite;
  final int? unplayedItemCount;

  /// On the watchlist: Jellyfin's "liked" flag, which KefinTweaks' web
  /// watchlist uses too, so both show the same list.
  final bool likes;

  bool get hasProgress => playbackPositionTicks > 0 && !played;

  UserItemData copyWith({bool? played, bool? isFavorite, bool? likes}) => UserItemData(
        playbackPositionTicks: played == true ? 0 : playbackPositionTicks,
        playedPercentage: played == true ? null : playedPercentage,
        played: played ?? this.played,
        isFavorite: isFavorite ?? this.isFavorite,
        unplayedItemCount: played == true ? 0 : unplayedItemCount,
        likes: likes ?? this.likes,
      );
}

class PersonInfo {
  const PersonInfo({
    required this.id,
    required this.name,
    this.role,
    this.type,
    this.primaryImageTag,
  });

  factory PersonInfo.fromJson(Map<String, dynamic> json) => PersonInfo(
        id: json['Id'] as String,
        name: json['Name'] as String? ?? '',
        role: json['Role'] as String?,
        type: json['Type'] as String?,
        primaryImageTag: json['PrimaryImageTag'] as String?,
      );

  final String id;
  final String name;
  final String? role;

  /// Actor, Director, Writer, ...
  final String? type;
  final String? primaryImageTag;
}

/// A reference to an image on a specific item (which may be the item
/// itself or a parent such as the series, for episodes without art).
class ImageRef {
  const ImageRef(this.itemId, this.type, this.tag);

  final String itemId;

  /// Primary, Backdrop, Thumb, Logo, ...
  final String type;
  final String tag;

  // The same picture is equal: a key for what's worked out from it once
  // (its colour), not again on every rebuild.
  @override
  bool operator ==(Object other) =>
      other is ImageRef && other.itemId == itemId && other.type == type && other.tag == tag;

  @override
  int get hashCode => Object.hash(itemId, type, tag);
}

class BaseItem {
  const BaseItem({
    required this.id,
    required this.name,
    required this.type,
    this.raw = const {},
    this.originalTitle,
    this.overview,
    this.taglines = const [],
    this.collectionType,
    this.seriesId,
    this.seriesName,
    this.seasonId,
    this.seasonName,
    this.indexNumber,
    this.parentIndexNumber,
    this.productionYear,
    this.premiereDate,
    this.endDate,
    this.status,
    this.communityRating,
    this.criticRating,
    this.officialRating,
    this.runTimeTicks,
    this.childCount,
    this.genres = const [],
    this.studios = const [],
    this.people = const [],
    this.providerIds = const {},
    this.imageTags = const {},
    this.backdropImageTags = const [],
    this.parentBackdropItemId,
    this.parentBackdropImageTags = const [],
    this.parentThumbItemId,
    this.parentThumbImageTag,
    this.parentLogoItemId,
    this.parentLogoImageTag,
    this.seriesPrimaryImageTag,
    this.primaryImageAspectRatio,
    this.userData = const UserItemData(),
  });

  factory BaseItem.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) =>
        (json[key] as List<dynamic>?)?.whereType<String>().toList() ??
        const [];

    return BaseItem(
      raw: json,
      id: json['Id'] as String,
      name: json['Name'] as String? ?? '',
      type: ItemType.parse(json['Type'] as String?),
      originalTitle: json['OriginalTitle'] as String?,
      overview: switch (json['Overview']) {
        final String o => htmlToPlainText(o),
        _ => null,
      },
      taglines: strings('Taglines'),
      collectionType: json['CollectionType'] as String?,
      seriesId: json['SeriesId'] as String?,
      seriesName: json['SeriesName'] as String?,
      seasonId: json['SeasonId'] as String?,
      seasonName: json['SeasonName'] as String?,
      indexNumber: (json['IndexNumber'] as num?)?.toInt(),
      parentIndexNumber: (json['ParentIndexNumber'] as num?)?.toInt(),
      productionYear: (json['ProductionYear'] as num?)?.toInt(),
      premiereDate: DateTime.tryParse(json['PremiereDate'] as String? ?? ''),
      endDate: DateTime.tryParse(json['EndDate'] as String? ?? ''),
      status: json['Status'] as String?,
      communityRating: (json['CommunityRating'] as num?)?.toDouble(),
      criticRating: (json['CriticRating'] as num?)?.toDouble(),
      officialRating: json['OfficialRating'] as String?,
      runTimeTicks: (json['RunTimeTicks'] as num?)?.toInt(),
      childCount: (json['ChildCount'] as num?)?.toInt(),
      genres: strings('Genres'),
      studios: (json['Studios'] as List<dynamic>?)
              ?.map((s) => (s as Map<String, dynamic>)['Name'] as String? ?? '')
              .where((s) => s.isNotEmpty)
              .toList() ??
          const [],
      people: (json['People'] as List<dynamic>?)
              ?.map((p) => PersonInfo.fromJson(p as Map<String, dynamic>))
              .toList() ??
          const [],
      providerIds: (json['ProviderIds'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, '$v')) ??
          const {},
      imageTags: (json['ImageTags'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          const {},
      backdropImageTags: strings('BackdropImageTags'),
      parentBackdropItemId: json['ParentBackdropItemId'] as String?,
      parentBackdropImageTags: strings('ParentBackdropImageTags'),
      parentThumbItemId: json['ParentThumbItemId'] as String?,
      parentThumbImageTag: json['ParentThumbImageTag'] as String?,
      parentLogoItemId: json['ParentLogoItemId'] as String?,
      parentLogoImageTag: json['ParentLogoImageTag'] as String?,
      seriesPrimaryImageTag: json['SeriesPrimaryImageTag'] as String?,
      primaryImageAspectRatio:
          (json['PrimaryImageAspectRatio'] as num?)?.toDouble(),
      userData: UserItemData.fromJson(json['UserData'] as Map<String, dynamic>?),
    );
  }

  final Map<String, dynamic> raw;
  final String id;
  final String name;
  final ItemType type;
  final String? originalTitle;
  final String? overview;
  final List<String> taglines;

  /// For library views: movies, tvshows, boxsets, playlists, music, ...
  final String? collectionType;
  final String? seriesId;
  final String? seriesName;
  final String? seasonId;
  final String? seasonName;

  /// Episode number, or season number for seasons.
  final int? indexNumber;

  /// Season number, for episodes.
  final int? parentIndexNumber;
  final int? productionYear;
  final DateTime? premiereDate;
  final DateTime? endDate;

  /// For series: Continuing / Ended.
  final String? status;
  final double? communityRating;
  final double? criticRating;
  final String? officialRating;
  final int? runTimeTicks;
  final int? childCount;
  final List<String> genres;
  final List<String> studios;
  final List<PersonInfo> people;

  /// External IDs: AniDB, AniList, Tvdb, Tmdb, Imdb, ...
  final Map<String, String> providerIds;

  /// A placeholder for an episode the server doesn't have (Jellyfin's
  /// "display missing episodes"), not a file.
  bool get isVirtual => raw['LocationType'] == 'Virtual';

  /// The server's tags (detail pages ask for them).
  List<String> get tags => [for (final t in raw['Tags'] as List? ?? const []) if (t is String) t];

  /// Trailer files of its own (`<show>/Trailers/`), when asked for.
  int get localTrailerCount => (raw['LocalTrailerCount'] as num?)?.toInt() ?? 0;
  final Map<String, String> imageTags;
  final List<String> backdropImageTags;
  final String? parentBackdropItemId;
  final List<String> parentBackdropImageTags;
  final String? parentThumbItemId;
  final String? parentThumbImageTag;
  final String? parentLogoItemId;
  final String? parentLogoImageTag;
  final String? seriesPrimaryImageTag;
  final double? primaryImageAspectRatio;
  final UserItemData userData;

  Duration? get runtime =>
      runTimeTicks == null ? null : ticksToDuration(runTimeTicks!);

  /// Portrait poster: the item's own, falling back to the series poster.
  ImageRef? get posterImage {
    final own = imageTags['Primary'];
    if (own != null) return ImageRef(id, 'Primary', own);
    if (seriesId != null && seriesPrimaryImageTag != null) {
      return ImageRef(seriesId!, 'Primary', seriesPrimaryImageTag!);
    }
    return null;
  }

  /// Landscape image for wide cards (continue watching, episodes).
  ///
  /// Episodes use their own still (Primary); others prefer a Thumb, then a
  /// backdrop, including the parent series' art.
  ImageRef? get landscapeImage {
    if (type == ItemType.episode && imageTags['Primary'] != null) {
      return ImageRef(id, 'Primary', imageTags['Primary']!);
    }
    final thumb = imageTags['Thumb'];
    if (thumb != null) return ImageRef(id, 'Thumb', thumb);
    if (parentThumbItemId != null && parentThumbImageTag != null) {
      return ImageRef(parentThumbItemId!, 'Thumb', parentThumbImageTag!);
    }
    return backdropImage;
  }

  ImageRef? get backdropImage {
    if (backdropImageTags.isNotEmpty) {
      return ImageRef(id, 'Backdrop', backdropImageTags.first);
    }
    if (parentBackdropItemId != null && parentBackdropImageTags.isNotEmpty) {
      return ImageRef(
        parentBackdropItemId!,
        'Backdrop',
        parentBackdropImageTags.first,
      );
    }
    return null;
  }

  ImageRef? get logoImage {
    final own = imageTags['Logo'];
    if (own != null) return ImageRef(id, 'Logo', own);
    if (parentLogoItemId != null && parentLogoImageTag != null) {
      return ImageRef(parentLogoItemId!, 'Logo', parentLogoImageTag!);
    }
    return null;
  }

  /// "S1:E3" for episodes, null otherwise.
  String? get episodeLabel {
    if (type != ItemType.episode) return null;
    final s = parentIndexNumber;
    final e = indexNumber;
    if (s == null && e == null) return null;
    return [if (s != null) 'S$s', if (e != null) 'E$e'].join(':');
  }

  /// Year or year range shown under titles ("2019", "2019–2023", "2021–").
  String? get yearLabel {
    final start = productionYear ?? premiereDate?.year;
    if (start == null) return null;
    if (type != ItemType.series) return '$start';
    final end = endDate?.year;
    if (status == 'Continuing') return '$start–';
    if (end != null && end != start) return '$start–$end';
    return '$start';
  }

  BaseItem copyWithUserData(UserItemData data) => BaseItem(
        raw: raw,
        id: id,
        name: name,
        type: type,
        originalTitle: originalTitle,
        overview: overview,
        taglines: taglines,
        collectionType: collectionType,
        seriesId: seriesId,
        seriesName: seriesName,
        seasonId: seasonId,
        seasonName: seasonName,
        indexNumber: indexNumber,
        parentIndexNumber: parentIndexNumber,
        productionYear: productionYear,
        premiereDate: premiereDate,
        endDate: endDate,
        status: status,
        communityRating: communityRating,
        criticRating: criticRating,
        officialRating: officialRating,
        runTimeTicks: runTimeTicks,
        childCount: childCount,
        genres: genres,
        studios: studios,
        people: people,
        providerIds: providerIds,
        imageTags: imageTags,
        backdropImageTags: backdropImageTags,
        parentBackdropItemId: parentBackdropItemId,
        parentBackdropImageTags: parentBackdropImageTags,
        parentThumbItemId: parentThumbItemId,
        parentThumbImageTag: parentThumbImageTag,
        parentLogoItemId: parentLogoItemId,
        parentLogoImageTag: parentLogoImageTag,
        seriesPrimaryImageTag: seriesPrimaryImageTag,
        primaryImageAspectRatio: primaryImageAspectRatio,
        userData: data,
      );
}

/// One page of a paged item query.
class ItemPage {
  const ItemPage({
    required this.items,
    required this.totalCount,
    required this.startIndex,
  });

  factory ItemPage.fromJson(Map<String, dynamic> json) => ItemPage(
        items: (json['Items'] as List<dynamic>? ?? const [])
            .map((e) => BaseItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalCount: (json['TotalRecordCount'] as num?)?.toInt() ?? 0,
        startIndex: (json['StartIndex'] as num?)?.toInt() ?? 0,
      );

  final List<BaseItem> items;
  final int totalCount;
  final int startIndex;
}


/// Overviews from some metadata providers (e.g. AniDB via ANN) contain HTML:
/// line breaks become newlines, other tags are dropped, common entities
/// are decoded.
String htmlToPlainText(String html) {
  var text = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  const entities = {
    '&nbsp;': ' ',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&lt;': '<',
    '&gt;': '>',
    '&amp;': '&', // last, so "&amp;lt;" stays "&lt;"
  };
  entities.forEach((entity, char) => text = text.replaceAll(entity, char));
  text = text.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => String.fromCharCode(int.parse(m[1]!)),
  );
  return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
