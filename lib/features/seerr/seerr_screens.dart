import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/toast.dart';
import '../../app/layout.dart';
import '../../core/seerr/seerr_api.dart';
import '../library/widgets/item_image.dart';
import 'request_window.dart';
import 'seerr_providers.dart';
import 'widgets/seerr_widgets.dart';

/// A Seerr title: overview, availability (per season for shows) and Request.
class SeerrDetailScreen extends ConsumerWidget {
  const SeerrDetailScreen({super.key, required this.type, required this.tmdbId});

  final SeerrMediaType type;
  final int tmdbId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = ref.watch(seerrDetailsProvider((type: type, tmdbId: tmdbId)));
    final user = ref.watch(seerrAccountProvider).value?.user;
    final layout = context.layout;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(),
      body: switch (details) {
        AsyncData(:final value) => ListView(
            padding: EdgeInsets.all(layout.gutter),
            children: [
              Wrap(
                spacing: 24,
                runSpacing: 16,
                children: [
                  if (value.media.poster() case final poster?)
                    SizedBox(
                      width: layout.posterWidth,
                      child: AspectRatio(
                        aspectRatio: 2 / 3,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: ref.watch(networkImageBuilderProvider)(
                            poster.toString(),
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            fallback: const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(value.media.title, style: theme.textTheme.headlineMedium),
                        const SizedBox(height: 4),
                        Text(
                          [
                            ?value.media.year?.toString(),
                            type == SeerrMediaType.movie ? 'Movie' : 'Series',
                            if (value.media.voteAverage case final v? when v > 0) '★ ${v.toStringAsFixed(1)} TMDB',
                          ].join('  ·  '),
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 12),
                        SeerrStatusBadge(status: value.media.status),
                        const SizedBox(height: 16),
                        _RequestButton(details: value, user: user),
                        if (value.media.overview case final o? when o.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(o, style: theme.textTheme.bodyLarge),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (value.seasons.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('Seasons', style: theme.textTheme.titleLarge),
                for (final s in value.seasons)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.name),
                    subtitle: s.episodeCount == null ? null : Text('${s.episodeCount} episodes'),
                    trailing: SeerrStatusBadge(status: s.status),
                  ),
              ],
            ],
          ),
        AsyncError(:final error) => Center(child: Text('$error')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _RequestButton extends ConsumerWidget {
  const _RequestButton({required this.details, required this.user});

  final SeerrDetails details;
  final SeerrUser? user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = details.media;
    final missing = details.seasons.where((s) => s.status.requestable).toList();
    final wanted = media.type == SeerrMediaType.movie ? media.status.requestable : missing.isNotEmpty;
    // Requestable, but not by this account: say so rather than show nothing.
    if (wanted && user != null && !user!.canRequest(media.type)) {
      return Text(
        "This Seerr account can't request ${media.type == SeerrMediaType.movie ? 'movies' : 'shows'}."
        ' Ask the Seerr owner for request permission.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
    final canAsk = user != null && user!.canRequest(media.type) && wanted;
    if (!canAsk) return const SizedBox.shrink();
    return FilledButton.icon(
      autofocus: true,
      icon: const Icon(Icons.add_circle_outline),
      label: Text(media.status == SeerrMediaStatus.partiallyAvailable ? 'Request more' : 'Request'),
      onPressed: () {
        final box = context.findRenderObject() as RenderBox?;
        showSeerrRequest(context, media, from: box == null ? null : box.localToGlobal(Offset.zero) & box.size);
      },
    );
  }
}

/// Seasons (TV), 4K and — for users allowed advanced requests — server,
/// quality profile and root folder; then sends the request.
class SeerrRequestSheet extends ConsumerStatefulWidget {
  const SeerrRequestSheet({super.key, required this.details, required this.user});

  final SeerrDetails details;
  final SeerrUser user;

  @override
  ConsumerState<SeerrRequestSheet> createState() => _SeerrRequestSheetState();
}

class _SeerrRequestSheetState extends ConsumerState<SeerrRequestSheet> {
  late final Set<int> _seasons = {
    for (final s in widget.details.seasons)
      if (s.status.requestable) s.number,
  };
  bool _is4k = false;
  int? _serverId;
  int? _profileId;
  String? _rootFolder;
  bool _busy = false;
  String? _error;

  SeerrMediaType get _type => widget.details.media.type;

  /// Anime, as Seerr decides it: Sonarr's anime defaults apply.
  bool get _anime => widget.details.isAnime;

  static String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(2)} GB';

  Future<void> _send() async {
    final api = ref.read(seerrApiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.request(
        _type,
        widget.details.media.tmdbId,
        seasons: _type == SeerrMediaType.tv ? (_seasons.toList()..sort()) : null,
        is4k: _is4k,
        serverId: _serverId,
        profileId: _profileId,
        rootFolder: _rootFolder,
      );
      ref.invalidate(seerrDetailsProvider);
      ref.invalidate(seerrRequestsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      showToast('Requested ${widget.details.media.title}.');
    } on SeerrException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = widget.user;
    final seasons = widget.details.seasons;
    final services = user.canRequestAdvanced ? ref.watch(seerrServicesProvider(_type)).value : null;
    final eligible = services?.where((s) => s.is4k == _is4k).toList() ?? const <SeerrService>[];
    final server = eligible.where((s) => s.id == _serverId).firstOrNull ??
        eligible.where((s) => s.isDefault).firstOrNull ??
        eligible.firstOrNull;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Request ${widget.details.media.title}', style: theme.textTheme.titleLarge),
            if (_type == SeerrMediaType.tv) ...[
              const SizedBox(height: 12),
              Text('Seasons', style: theme.textTheme.titleSmall),
              for (final s in seasons)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(s.name),
                  subtitle: s.status.requestable ? null : Text(s.status.label),
                  value: s.status.requestable ? _seasons.contains(s.number) : true,
                  onChanged: !s.status.requestable
                      ? null
                      : (v) => setState(() => v == true ? _seasons.add(s.number) : _seasons.remove(s.number)),
                ),
            ],
            if (user.canRequest4k(_type))
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Request in 4K'),
                value: _is4k,
                onChanged: (v) => setState(() {
                  _is4k = v;
                  _serverId = _profileId = null;
                  _rootFolder = null;
                }),
              ),
            if (server != null) ...[
              const SizedBox(height: 8),
              Text('Advanced', style: theme.textTheme.titleSmall),
              if (eligible.length > 1)
                _dropdown<int>(
                  'Server',
                  server.id,
                  {for (final s in eligible) s.id: s.name},
                  (v) => setState(() {
                    _serverId = v;
                    _profileId = null;
                    _rootFolder = null;
                  }),
                ),
              // What Seerr uses when left alone (for anime: Sonarr's anime
              // defaults), marked (Default); only a change is sent.
              if (server.profiles.isNotEmpty)
                _dropdown<int>(
                  'Quality profile',
                  _profileId ?? server.defaultProfileFor(anime: _anime) ?? server.profiles.first.id,
                  {
                    for (final p in server.profiles)
                      p.id: p.id == server.defaultProfileFor(anime: _anime) ? '${p.name} (Default)' : p.name,
                  },
                  (v) => setState(() => _profileId = v),
                ),
              if (server.rootFolders.isNotEmpty)
                _dropdown<String>(
                  'Root folder',
                  _rootFolder ?? server.defaultFolderFor(anime: _anime) ?? server.rootFolders.first,
                  {
                    for (final f in server.rootFolders)
                      f: [
                        f,
                        if (server.freeSpace[f] case final free?) '(${_gb(free)})',
                        if (f == server.defaultFolderFor(anime: _anime)) '(Default)',
                      ].join(' '),
                  },
                  (v) => setState(() => _rootFolder = v),
                ),
              if (_anime)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('* This series is an anime.', style: theme.textTheme.bodySmall),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || (_type == SeerrMediaType.tv && _seasons.isEmpty) ? null : _send,
              child: Text(_busy ? 'Requesting…' : 'Request'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dropdown<T>(String label, T value, Map<T, String> options, ValueChanged<T> onChanged) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: DropdownButtonFormField<T>(
          initialValue: options.containsKey(value) ? value : options.keys.first,
          // Long labels ("/media/anime (445.52 GB) (Default)") fit the small
          // request window.
          isExpanded: true,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          items: [
            for (final e in options.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      );
}

/// The user's requests (and everyone's, for request managers), with
/// approve / decline / cancel.
class SeerrRequestsScreen extends ConsumerWidget {
  const SeerrRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(seerrAccountProvider).value?.user;
    final manager = user?.canManageRequests ?? false;
    return DefaultTabController(
      length: manager ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Requests'),
          bottom: manager
              ? const TabBar(tabs: [Tab(text: 'Mine'), Tab(text: 'All')])
              : null,
        ),
        body: user == null
            ? const Center(child: Text('Sign in to Seerr in Settings.'))
            : TabBarView(
                children: [
                  const _RequestList(everyone: false),
                  if (manager) const _RequestList(everyone: true),
                ],
              ),
      ),
    );
  }
}

class _RequestList extends ConsumerWidget {
  const _RequestList({required this.everyone});

  final bool everyone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(seerrRequestsProvider(everyone));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(seerrRequestsProvider(everyone).future),
      child: switch (requests) {
        AsyncData(:final value) when value.isEmpty => ListView(
            children: const [Padding(padding: EdgeInsets.all(48), child: Center(child: Text('No requests yet.')))],
          ),
        AsyncData(:final value) => ListView(
            children: [for (final r in value) _RequestTile(request: r, everyone: everyone)],
          ),
        AsyncError(:final error) => ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('$error'))]),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile({required this.request, required this.everyone});

  final SeerrRequest request;
  final bool everyone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = ref.watch(seerrDetailsProvider((type: request.type, tmdbId: request.tmdbId))).value;
    final user = ref.watch(seerrAccountProvider).value?.user;
    final theme = Theme.of(context);
    final pending = request.status == SeerrRequestStatus.pending;

    Future<void> act(Future<void> Function(SeerrApi api) call, String done) async {
      final api = ref.read(seerrApiProvider);
      if (api == null) return;
      try {
        await call(api);
        ref.invalidate(seerrRequestsProvider);
        showToast(done);
      } on SeerrException catch (e) {
        showToast(e.message);
      }
    }

    final title = details?.media.title ?? '…';
    return ListTile(
      onTap: details == null ? null : () => openSeerrMedia(context, details.media),
      title: Text(title),
      subtitle: Text([
        request.status.label,
        if (request.mediaStatus != SeerrMediaStatus.unknown) request.mediaStatus.label,
        if (request.seasons.isNotEmpty) 'Seasons ${request.seasons.join(', ')}',
        if (request.is4k) '4K',
        if (everyone) 'by ${request.requestedBy.displayName}',
        MaterialLocalizations.of(context).formatShortDate(request.createdAt.toLocal()),
      ].join(' · ')),
      leading: Icon(
        switch ((request.status, request.mediaStatus)) {
          (_, SeerrMediaStatus.available) => Icons.check_circle,
          (SeerrRequestStatus.declined, _) => Icons.block,
          (SeerrRequestStatus.pending, _) => Icons.hourglass_empty,
          _ => Icons.downloading,
        },
        color: request.mediaStatus == SeerrMediaStatus.available ? theme.colorScheme.primary : null,
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (pending && everyone && (user?.canManageRequests ?? false)) ...[
            IconButton(
              tooltip: 'Approve',
              icon: const Icon(Icons.check),
              onPressed: () => act((a) => a.approve(request.id), 'Approved $title.'),
            ),
            IconButton(
              tooltip: 'Decline',
              icon: const Icon(Icons.close),
              onPressed: () => act((a) => a.decline(request.id), 'Declined $title.'),
            ),
          ],
          if (pending && !everyone)
            IconButton(
              tooltip: 'Cancel request',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => act((a) => a.cancel(request.id), 'Cancelled $title.'),
            ),
        ],
      ),
    );
  }
}
