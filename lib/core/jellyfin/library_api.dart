import 'items.dart';
import 'jellyfin_api.dart';

/// Extra fields requested for list views. Kept small: grids load hundreds.
const listFields = 'PrimaryImageAspectRatio,ChildCount,Genres,ProviderIds';

/// Fields for detail pages.
const detailFields = 'Overview,Genres,Tags,People,Studios,ProviderIds,Taglines,'
    'OriginalTitle,ChildCount,PrimaryImageAspectRatio,RemoteTrailers,'
    'MediaSources,Chapters,Trickplay';

const _imageTypes = 'Primary,Backdrop,Thumb,Logo';

enum SortField {
  name('SortName', 'Name'),
  dateAdded('DateCreated', 'Date added'),
  premiereDate('PremiereDate', 'Release date'),
  communityRating('CommunityRating', 'Rating'),
  datePlayed('DatePlayed', 'Last watched'),
  random('Random', 'Random');

  const SortField(this.apiName, this.label);

  final String apiName;
  final String label;
}

/// Filters and sorting for a library grid.
/// Something left to watch: Jellyfin's "unplayed" filter lets through shows
/// that are watched (or have no episodes left, just a folder); a show counts
/// only with unwatched episodes.
bool hasSomethingToWatch(BaseItem item) {
  if (item.userData.played) return false;
  if (item.type == ItemType.series || item.type == ItemType.season) {
    return (item.userData.unplayedItemCount ?? 0) > 0;
  }
  return true;
}

class ItemQuery {
  const ItemQuery({
    this.parentId,
    this.includeItemTypes = const [],
    this.recursive = true,
    this.sortBy = SortField.name,
    this.descending = false,
    this.unplayedOnly = false,
    this.favoritesOnly = false,
    this.genres = const [],
    this.searchTerm,
    this.extraFilters = const [],
  });

  final String? parentId;
  final List<ItemType> includeItemTypes;
  final bool recursive;
  final SortField sortBy;
  final bool descending;
  final bool unplayedOnly;
  final bool favoritesOnly;
  final List<String> genres;
  final String? searchTerm;

  /// More Jellyfin `filters` values, e.g. IsResumable, IsPlayed.
  final List<String> extraFilters;

  ItemQuery copyWith({
    SortField? sortBy,
    bool? descending,
    bool? unplayedOnly,
    bool? favoritesOnly,
    List<String>? genres,
  }) =>
      ItemQuery(
        parentId: parentId,
        includeItemTypes: includeItemTypes,
        recursive: recursive,
        sortBy: sortBy ?? this.sortBy,
        descending: descending ?? this.descending,
        unplayedOnly: unplayedOnly ?? this.unplayedOnly,
        favoritesOnly: favoritesOnly ?? this.favoritesOnly,
        genres: genres ?? this.genres,
        searchTerm: searchTerm,
        extraFilters: extraFilters,
      );

  Map<String, dynamic> toQuery() {
    final filters = [
      if (unplayedOnly) 'IsUnplayed',
      if (favoritesOnly) 'IsFavorite',
      ...extraFilters,
    ];
    return {
      'parentId': parentId,
      'includeItemTypes': includeItemTypes.isEmpty
          ? null
          : includeItemTypes.map((t) => t.apiName).join(','),
      'recursive': recursive,
      // Secondary sort keeps paging stable when the primary key ties.
      'sortBy': sortBy == SortField.name
          ? 'SortName'
          : '${sortBy.apiName},SortName',
      'sortOrder': descending ? 'Descending' : 'Ascending',
      'filters': filters.isEmpty ? null : filters.join(','),
      'genres': genres.isEmpty ? null : genres.join('|'),
      'searchTerm': searchTerm,
    };
  }
}

/// Item types to show in a library grid, by its collection type.
List<ItemType> itemTypesForCollection(String? collectionType) =>
    switch (collectionType) {
      'movies' => const [ItemType.movie],
      'tvshows' => const [ItemType.series],
      'boxsets' => const [ItemType.boxSet],
      'playlists' => const [ItemType.playlist],
      'music' => const [ItemType.musicAlbum],
      _ => const [],
    };

/// Library browsing endpoints (Jellyfin 10.9+ paths).
class LibraryApi {
  LibraryApi(this._api, {required this.userId});

  final JellyfinApi _api;
  final String userId;

  Map<String, dynamic> _common([Map<String, dynamic> extra = const {}]) => {
        'userId': userId,
        'enableImageTypes': _imageTypes,
        'imageTypeLimit': 1,
        'enableUserData': true,
        ...extra,
      };

  /// The user's libraries (Movies, Shows, Anime, Collections, ...).
  Future<List<BaseItem>> getViews() async {
    final data = await _api.getJson('/UserViews', query: {'userId': userId});
    return ItemPage.fromJson(data).items;
  }

  Future<List<BaseItem>> getResume({int limit = 24}) async {
    final data = await _api.getJson(
      '/UserItems/Resume',
      query: _common({
        'limit': limit,
        'mediaTypes': 'Video',
        'fields': listFields,
      }),
    );
    return ItemPage.fromJson(data).items;
  }

  Future<List<BaseItem>> getNextUp({int limit = 24, String? seriesId}) async {
    final data = await _api.getJson(
      '/Shows/NextUp',
      query: _common({
        'limit': limit,
        'seriesId': seriesId,
        'fields': listFields,
        // Without this, a show you just started is skipped until
        // you watch a second episode.
        'enableResumable': false,
        'enableRewatching': false,
      }),
    );
    return ItemPage.fromJson(data).items;
  }

  /// Recently added items in a library. Episodes are grouped by series.
  Future<List<BaseItem>> getLatest(String parentId, {int limit = 24}) async {
    final data = await _api.getList(
      '/Items/Latest',
      query: _common({
        'parentId': parentId,
        'limit': limit,
        'fields': listFields,
        'groupItems': true,
      }),
    );
    return data
        .map((e) => BaseItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ItemPage> getItems(
    ItemQuery query, {
    int startIndex = 0,
    int limit = 100,
    String fields = listFields,
  }) async {
    final data = await _api.getJson(
      '/Items',
      query: _common({
        ...query.toQuery(),
        'startIndex': startIndex,
        'limit': limit,
        'fields': fields,
        'enableTotalRecordCount': true,
      }),
    );
    return ItemPage.fromJson(data);
  }

  /// For Home's header: items with what the header shows (overview, genres,
  /// ratings, seasons, trailers, logo / backdrop).
  static const featuredFields =
      'Overview,Genres,OfficialRating,CommunityRating,ProductionYear,ChildCount,ProviderIds,LocalTrailerCount';

  /// [ids] in that order, with [featuredFields].
  Future<List<BaseItem>> getFeatured(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final data = await _api.getJson('/Items', query: _common({'ids': ids.join(','), 'fields': featuredFields}));
    final byId = {for (final i in ItemPage.fromJson(data).items) i.id: i};
    return [for (final id in ids) ?byId[id]];
  }

  /// Shows and movies with artwork, in random order (Home's header).
  Future<List<BaseItem>> getRandomFeatured({int limit = 10}) async {
    final data = await _api.getJson('/Items', query: _common({
      'includeItemTypes': 'Series,Movie',
      'recursive': true,
      'sortBy': 'Random',
      'imageTypes': 'Backdrop',
      'limit': limit,
      'fields': featuredFields,
    }));
    return ItemPage.fromJson(data).items;
  }

  /// Items in library [parentId] with a backdrop, in random order (its door).
  Future<List<BaseItem>> getRandomWithBackdrop(String parentId, List<ItemType> types, {int limit = 8}) async {
    final data = await _api.getJson('/Items', query: _common({
      'parentId': parentId,
      if (types.isNotEmpty) 'includeItemTypes': types.map((t) => t.apiName).join(','),
      'recursive': true,
      'sortBy': 'Random',
      'imageTypes': 'Backdrop',
      'limit': limit,
      'fields': featuredFields,
    }));
    return ItemPage.fromJson(data).items;
  }

  /// An item's own trailer files (e.g. `<show>/Trailers/`).
  Future<List<BaseItem>> getLocalTrailers(String itemId) async {
    try {
      return [
        for (final t in await _api.getList('/Items/$itemId/LocalTrailers', query: {'userId': userId}))
          BaseItem.fromJson(t as Map<String, dynamic>),
      ];
    } on JellyfinException catch (e) {
      // Servers before 10.9 only know the older address.
      if (e.statusCode != 404) rethrow;
      return [
        for (final t in await _api.getList('/Users/$userId/Items/$itemId/LocalTrailers'))
          BaseItem.fromJson(t as Map<String, dynamic>),
      ];
    }
  }

  Future<BaseItem> getItem(String itemId) async {
    final data = await _api.getJson(
      '/Items/$itemId',
      query: {'userId': userId, 'fields': detailFields},
    );
    return BaseItem.fromJson(data);
  }

  Future<List<BaseItem>> getSeasons(String seriesId) async {
    final data = await _api.getJson(
      '/Shows/$seriesId/Seasons',
      query: _common({'fields': listFields}),
    );
    return ItemPage.fromJson(data).items;
  }

  Future<List<BaseItem>> getEpisodes(
    String seriesId, {
    String? seasonId,
    String? startItemId,
    int? limit,
    String fields = 'Overview,PrimaryImageAspectRatio',
  }) async {
    final data = await _api.getJson(
      '/Shows/$seriesId/Episodes',
      query: _common({
        'seasonId': seasonId,
        'startItemId': startItemId,
        'limit': limit,
        'fields': fields,
      }),
    );
    return ItemPage.fromJson(data).items;
  }

  /// An item with just enough fields for matching it to other databases
  /// (provider IDs, season number) — far lighter than [getItem].
  Future<BaseItem> getItemIds(String id) async {
    final data = await _api.getJson(
      '/Items/$id',
      query: {'userId': userId, 'fields': 'ProviderIds'},
    );
    return BaseItem.fromJson(data);
  }

  Future<List<BaseItem>> getSimilar(String itemId, {int limit = 16}) async {
    final data = await _api.getJson(
      '/Items/$itemId/Similar',
      query: _common({'limit': limit, 'fields': listFields}),
    );
    return ItemPage.fromJson(data).items;
  }

  /// Movies, shows and episodes matching [term], in one request.
  Future<List<BaseItem>> search(String term, {int limit = 60}) async {
    final page = await getItems(
      ItemQuery(
        searchTerm: term,
        includeItemTypes: const [
          ItemType.movie,
          ItemType.series,
          ItemType.episode,
          ItemType.boxSet,
        ],
      ),
      limit: limit,
    );
    return page.items;
  }

  /// Genres in [parentId] (null: every library), of [type] only if given.
  Future<List<String>> getGenres(String? parentId, {ItemType? type}) async {
    final data = await _api.getJson(
      '/Genres',
      query: {'userId': userId, 'parentId': parentId, 'includeItemTypes': type?.apiName, 'sortBy': 'SortName'},
    );
    return ItemPage.fromJson(data).items.map((g) => g.name).toList();
  }

  /// The user's playlists.
  Future<List<BaseItem>> getPlaylists() async =>
      (await getItems(const ItemQuery(includeItemTypes: [ItemType.playlist]), limit: 200)).items;

  Future<void> addToPlaylist(String playlistId, List<String> itemIds) async {
    await _api.postJson('/Playlists/$playlistId/Items', query: {'ids': itemIds.join(','), 'userId': userId});
  }

  /// A playlist's entries in order, each with its PlaylistItemId.
  Future<List<BaseItem>> getPlaylistItems(String playlistId, {int limit = 500}) async {
    final data = await _api.getJson(
      '/Playlists/$playlistId/Items',
      query: _common({'limit': limit, 'fields': listFields}),
    );
    return ItemPage.fromJson(data).items;
  }

  /// Takes entries out of a playlist, by their PlaylistItemId (an entry, not
  /// the item: the same episode can be in a playlist twice).
  Future<void> removeFromPlaylist(String playlistId, List<String> entryIds) async {
    await _api.delete('/Playlists/$playlistId/Items', query: {'entryIds': entryIds.join(',')});
  }

  /// Moves an entry to [index] (0 = the top) in its playlist.
  Future<void> movePlaylistEntry(String playlistId, String entryId, int index) async {
    await _api.postJson('/Playlists/$playlistId/Items/$entryId/Move/$index');
  }

  /// Deletes a playlist (not what's in it).
  Future<void> deletePlaylist(String playlistId) async {
    await _api.delete('/Items/$playlistId');
  }

  /// A new playlist with [itemIds] in it; it can start empty. Video, so
  /// episodes and films can go in later.
  Future<void> createPlaylist(String name, List<String> itemIds) async {
    await _api.postJson('/Playlists', body: {'Name': name, 'Ids': itemIds, 'UserId': userId, 'MediaType': 'Video'});
  }

  Future<void> setFavorite(String itemId, bool favorite) async {
    const path = '/UserFavoriteItems';
    final query = {'userId': userId};
    if (favorite) {
      await _api.postJson('$path/$itemId', query: query);
    } else {
      await _api.delete('$path/$itemId', query: query);
    }
  }

  /// Forgets the resume point, taking the item off Continue watching.
  Future<void> clearProgress(String itemId) async {
    await _api.postJson(
      '/UserItems/$itemId/UserData',
      query: {'userId': userId},
      body: {'PlaybackPositionTicks': 0},
    );
  }

  /// The watchlist: everything with Jellyfin's "liked" flag, as KefinTweaks'
  /// web watchlist keeps it (movies, shows, seasons and episodes).
  Future<List<BaseItem>> getWatchlist() async {
    final page = await getItems(
      const ItemQuery(
        includeItemTypes: [ItemType.movie, ItemType.series, ItemType.season, ItemType.episode],
        recursive: true,
        extraFilters: ['Likes'],
      ),
      limit: 1000,
      fields: '$listFields,Overview,DateCreated',
    );
    return page.items;
  }

  /// Puts [itemId] on the watchlist or takes it off ("liked" or not).
  Future<void> setWatchlisted(String itemId, bool on) async {
    await _api.postJson('/UserItems/$itemId/Rating', query: {'userId': userId, 'likes': on});
  }

  Future<void> setPlayed(String itemId, bool played) async {
    const path = '/UserPlayedItems';
    final query = {'userId': userId};
    if (played) {
      await _api.postJson('$path/$itemId', query: query);
    } else {
      await _api.delete('$path/$itemId', query: query);
    }
  }
}
