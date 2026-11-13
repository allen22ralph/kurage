import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../admin/admin_providers.dart';
import '../admin/server_admin.dart';
import '../player/playback_log.dart';
import '../../app/toast.dart';
import '../../app/layout.dart';
import '../../app/providers.dart';
import '../../core/net/trusted_certificates.dart';
import '../seerr/seerr_settings.dart';
import '../../core/anime/mal_auth.dart';
import '../anime/anime_settings.dart';
import '../anime/mal_account.dart';
import '../../app/connection_check.dart';
import '../home/home_actions.dart';
import '../home/home_header_settings.dart';
import '../library/widgets/episode_swipe.dart';
import '../player/widgets/player_look_settings.dart';
import 'app_log_screen.dart';
import 'keybindings.dart';
import 'playback_settings.dart';
import 'appearance.dart';
import '../../app/app_dropdown.dart';
import '../update/update_ui.dart';

/// The parts of Settings, each a page of its own (#85).
enum SettingsCategory {
  account('Account & server', Icons.account_circle_outlined, 'Signed-in account, accounts, trusted certificates'),
  server('Server', Icons.dns_outlined, 'Libraries, scheduled tasks, users, restart (administrators)'),
  playback('Playback', Icons.play_circle_outline, 'Languages, skipping, next episode, decoding'),
  controls('Player controls', Icons.keyboard_outlined, 'Player theme and layout; keyboard shortcuts or touch gestures'),
  home('Home', Icons.home_outlined, 'Header and trailers; which rows Home shows, and in what order'),
  appearance('Appearance', Icons.palette_outlined, 'Theme, font, accent colour, background, card size, animations'),
  seerr('Seerr', Icons.download_for_offline_outlined, 'Requests server and account'),
  anime('MyAnimeList', Icons.animation_outlined, 'Account, sync, skipping and titles for anime'),
  troubleshooting('Troubleshooting', Icons.bug_report_outlined, 'Logs for bug reports'),
  about('About', Icons.info_outline, 'Version, updates (Stable or Beta) and licences');

  const SettingsCategory(this.label, this.icon, this.description);

  final String label;
  final IconData icon;
  final String description;

  /// From a route's `?section=` (its name), or null.
  static SettingsCategory? fromName(String? name) =>
      SettingsCategory.values.where((c) => c.name == name).firstOrNull;
}

/// What a device shows in Settings: only what applies on it (no keyboard
/// shortcuts on a TV, no touch gestures on a desktop).
class SettingsDevice {
  const SettingsDevice({required this.isTv, required this.isAndroid, this.isAdmin = false});

  final bool isTv;
  final bool isAndroid;

  /// The signed-in user administers the server (Server is shown only then).
  final bool isAdmin;

  bool get keyboard => !isTv && !isAndroid;
  bool get touch => isAndroid && !isTv;

  List<SettingsCategory> get categories => [
        for (final c in SettingsCategory.values)
          if ((c != SettingsCategory.controls || keyboard || touch) && (c != SettingsCategory.server || isAdmin)) c,
      ];

  /// The settings in [category] by name, for the search box.
  List<String> settingsIn(SettingsCategory category) => switch (category) {
        SettingsCategory.account => const [
            'Accounts',
            'Sign out',
            'Approve a Quick Connect code',
            'Check connection',
            'Trusted certificates',
          ],
        SettingsCategory.server => const [
            'Scan all libraries',
            'Scheduled tasks',
            'Users',
            'Devices',
            'Restart server',
            'Shut down server',
          ],
        SettingsCategory.playback => [
            'Preferred audio languages',
            'Preferred subtitle languages',
            'Skip intros and recaps automatically',
            'Play next episode automatically',
            'Up next countdown',
            if (keyboard) 'Click video to play / pause',
            if (!isTv && !isAndroid) 'Hardware decoding',
          ],
        SettingsCategory.controls => [
            'Player layout',
            'Player theme',
            'Controls size',
            'Buttons',
            'Time',
            'Chapter marks on the seek bar',
            'Thumbnails while seeking',
            'Hide the controls after',
            'Top bar',
            if (keyboard) ...['Keyboard shortcuts', for (final a in PlayerAction.values) a.label],
            if (touch) ...[
              'Double-tap to skip',
              'Skip by',
              'Swipe for volume',
              "Swipe controls the phone's media volume",
              'Level indicator',
              'Swipe for brightness',
            ],
          ],
        SettingsCategory.home => [
            'Home rows',
            'Top bar',
            'Centre tabs',
            'Right toolbar',
            'Header',
            'Featured',
            'Trailers',
            'Trailers start muted',
            'Trailer volume',
            'Play each trailer for',
            if (isAndroid && !isTv) 'Trailers and previews on mobile data',
            'Previews in rows',
          ],
        SettingsCategory.appearance => [
            'Theme',
            if (!isTv) ...['Import a theme', 'Export this theme'],
            'Font',
            'Google Fonts',
            'Accent colour',
            'Background',
            'Card size',
            'Rows',
            'Animations',
            'Effects',
            if (touch) ...['Swiping episodes', 'Swipe left', 'Swipe right'],
          ],
        SettingsCategory.seerr => const ['Sign in to Seerr', 'Seerr account', 'Check connection'],
        SettingsCategory.anime => const [
            'Link MyAnimeList account',
            'Update my MyAnimeList as I watch',
            'Sync log',
            'Use AniSkip when the server has no segments',
            'Skip markers',
            'Show MyAnimeList scores',
            'Episode ratings out of 10',
            'Anime titles',
          ],
        SettingsCategory.troubleshooting => const ['App log', 'Playback log'],
        SettingsCategory.about => const [
            'Version',
            'Updates',
            'Update channel',
            'Check automatically',
            'Notify me about new versions',
            'Check for updates',
            'Beta',
            'Licences',
          ],
      };

  /// Settings whose name (or category's name) contains [query].
  List<({SettingsCategory category, String setting})> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return [
      for (final c in categories)
        for (final s in [c.label, ...settingsIn(c)])
          if (s.toLowerCase().contains(q)) (category: c, setting: s),
    ];
  }
}

/// Settings: categories on the left and the chosen one's settings on the
/// right on wide screens (desktop, TV); on phones, a list of categories that
/// each open their own page. A search box finds a setting by name.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.initial});

  /// The category to open with (e.g. Troubleshooting from a player error).
  final SettingsCategory? initial;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// The category last open on a wide screen, kept while the app runs.
  static SettingsCategory _last = SettingsCategory.playback;

  late SettingsCategory _selected = widget.initial ?? _last;
  final _search = TextEditingController();
  bool _openedInitial = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  SettingsDevice get _device => SettingsDevice(
        isTv: ref.read(isTvProvider),
        isAndroid: Platform.isAndroid,
        isAdmin: ref.watch(isAdminProvider).value ?? false,
      );

  void _select(SettingsCategory category, {required bool wide}) {
    _search.clear();
    if (wide) {
      setState(() => _selected = _last = category);
    } else {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsCategoryPage(category: category)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTv = ref.watch(isTvProvider);
    final wide = isTv || MediaQuery.sizeOf(context).width >= 720;
    final device = _device;
    if (!device.categories.contains(_selected)) _selected = SettingsCategory.playback;

    // Phones: a category asked for opens straight away, over the list.
    if (!wide && widget.initial != null && !_openedInitial) {
      _openedInitial = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _select(widget.initial!, wide: false);
      });
    }

    final list = _CategoryList(
      device: device,
      search: _search,
      selected: wide ? _selected : null,
      onSelect: (c) => _select(c, wide: wide),
      onSearch: () => setState(() {}),
    );

    if (!wide) {
      return Scaffold(appBar: AppBar(title: const Text('Settings')), body: list);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Two focus groups, so the D-pad moves within the sidebar or the
          // settings, and left / right between them.
          SizedBox(width: 300, child: FocusTraversalGroup(child: list)),
          const VerticalDivider(width: 1),
          Expanded(
            child: FocusTraversalGroup(
              child: KeyedSubtree(
                key: ValueKey(_selected),
                child: SettingsCategoryBody(category: _selected, showTitle: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The search box with the categories, or the matching settings while
/// searching.
class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.device,
    required this.search,
    required this.selected,
    required this.onSelect,
    required this.onSearch,
  });

  final SettingsDevice device;
  final TextEditingController search;
  final SettingsCategory? selected;
  final ValueChanged<SettingsCategory> onSelect;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final results = device.search(search.text);
    final searching = search.text.trim().isNotEmpty;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: TextField(
            controller: search,
            onChanged: (_) => onSearch(),
            decoration: InputDecoration(
              hintText: 'Search settings',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
              suffixIcon: searching
                  ? IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        search.clear();
                        onSearch();
                      },
                    )
                  : null,
            ),
          ),
        ),
        if (searching && results.isEmpty)
          const ListTile(title: Text('No settings match.')),
        if (searching)
          for (final r in results)
            ListTile(
              leading: Icon(r.category.icon),
              title: Text(r.setting),
              subtitle: r.setting == r.category.label ? null : Text(r.category.label),
              onTap: () => onSelect(r.category),
            )
        else
          for (final c in device.categories)
            ListTile(
              leading: Icon(c.icon),
              title: Text(c.label),
              subtitle: Text(c.description, maxLines: 2, overflow: TextOverflow.ellipsis),
              selected: c == selected,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
              trailing: selected == null ? const Icon(Icons.chevron_right) : null,
              onTap: () => onSelect(c),
            ),
      ],
    );
  }
}

/// One category on its own page (phones).
class SettingsCategoryPage extends StatelessWidget {
  const SettingsCategoryPage({super.key, required this.category});

  final SettingsCategory category;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(category.label)),
        body: SettingsCategoryBody(category: category),
      );
}

/// The settings of one category.
class SettingsCategoryBody extends ConsumerWidget {
  const SettingsCategoryBody({super.key, required this.category, this.showTitle = false});

  final SettingsCategory category;

  /// A heading with the category's name (wide screens, beside the sidebar).
  final bool showTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(playbackSettingsProvider);
    final device = SettingsDevice(isTv: ref.watch(isTvProvider), isAndroid: Platform.isAndroid);
    return switch (settings) {
      AsyncData(:final value) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (showTitle)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                child: Text(category.label, style: Theme.of(context).textTheme.headlineSmall),
              ),
            ..._children(context, ref, value, device),
          ],
        ),
      AsyncError(:final error) => Center(child: Text("Couldn't load settings: $error")),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  List<Widget> _children(BuildContext context, WidgetRef ref, PlaybackSettings value, SettingsDevice device) {
    final controller = ref.read(playbackSettingsProvider.notifier);
    switch (category) {
      case SettingsCategory.account:
        return const [
          _Section('Account'),
          _AccountTile(),
          _Section('Trusted certificates'),
          _TrustedCertificates(),
        ];
      case SettingsCategory.server:
        return const [SizedBox(height: 8), ServerAdminSection()];
      case SettingsCategory.playback:
        return [
          const _Section('Languages'),
          _LanguageTile(
            title: 'Preferred audio languages',
            hint: 'e.g. jpn,ja for Japanese audio',
            value: value.audioLanguages,
            onSaved: (v) => controller.save(value.copyWith(audioLanguages: v)),
          ),
          _LanguageTile(
            title: 'Preferred subtitle languages',
            hint: 'e.g. eng,en for English subtitles',
            value: value.subtitleLanguages,
            onSaved: (v) => controller.save(value.copyWith(subtitleLanguages: v)),
          ),
          const _Section('While watching'),
          SwitchListTile(
            title: const Text('Skip intros and recaps automatically'),
            subtitle: const Text('Otherwise a Skip button is shown'),
            value: value.autoSkipIntro,
            onChanged: (v) => controller.save(value.copyWith(autoSkipIntro: v)),
          ),
          SwitchListTile(
            title: const Text('Play next episode automatically'),
            value: value.autoPlayNext,
            onChanged: (v) => controller.save(value.copyWith(autoPlayNext: v)),
          ),
          ListTile(
            title: const Text('Default quality'),
            subtitle: const Text(
              'What every video starts at. Quality in the player changes it until the app closes. '
              'Auto lowers it by itself when playback keeps stopping to load',
            ),
            trailing: AppDropdown<StreamQuality>(
              value: value.defaultQuality,
              items: [for (final q in StreamQuality.values) DropdownMenuItem(value: q, child: Text(q.label))],
              onChanged: (q) => q == null ? null : controller.save(value.copyWith(defaultQuality: q)),
            ),
          ),
          if (device.keyboard)
            SwitchListTile(
              title: const Text('Click video to play / pause'),
              value: value.clickToPlayPause,
              onChanged: (v) => controller.save(value.copyWith(clickToPlayPause: v)),
            ),
          if (Platform.isWindows) ...[
            const _Section('Video'),
            ListTile(
              title: const Text('Hardware decoding'),
              subtitle: const Text('Copy back works with every file (as Jellyfin Media Player). Applies to the next video'),
              trailing: AppDropdown<HardwareDecoding>(
                value: value.hardwareDecoding,
                underline: const SizedBox.shrink(),
                items: [
                  for (final h in HardwareDecoding.values) DropdownMenuItem(value: h, child: Text(h.label)),
                ],
                onChanged: (h) => h == null ? null : controller.save(value.copyWith(hardwareDecoding: h)),
              ),
            ),
          ],
        ];
      case SettingsCategory.controls:
        return [
          const _Section('Player layout'),
          const PlayerLookSection(),
          // Keyboard shortcuts: desktop only (no keyboard on TV / phones).
          if (device.keyboard) ...[
            const _Section('Keyboard shortcuts'),
            const _PlayerControls(),
          ],
          // Touch gestures: phones only (not TV, not desktop).
          if (device.touch) ...[
            const _Section('Touch gestures'),
            SwitchListTile(
              title: const Text('Double-tap to skip'),
              subtitle: const Text('Left side back, right side ahead'),
              value: value.doubleTapSeek,
              onChanged: (v) => controller.save(value.copyWith(doubleTapSeek: v)),
            ),
            ListTile(
              title: const Text('Skip by'),
              enabled: value.doubleTapSeek,
              trailing: AppDropdown<int>(
                value: value.doubleTapSeconds,
                items: [
                  for (final s in const [5, 10, 15, 30]) DropdownMenuItem(value: s, child: Text('$s s')),
                ],
                onChanged: value.doubleTapSeek
                    ? (v) => v == null ? null : controller.save(value.copyWith(doubleTapSeconds: v))
                    : null,
              ),
            ),
            SwitchListTile(
              title: const Text('Swipe for volume'),
              subtitle: const Text('Up / down on the right side'),
              value: value.swipeVolume,
              onChanged: (v) => controller.save(value.copyWith(swipeVolume: v)),
            ),
            SwitchListTile(
              title: const Text("Swipe controls the phone's media volume"),
              subtitle: const Text("In step with the volume keys. Off: only the player's own volume"),
              value: value.swipeSystemVolume,
              onChanged: value.swipeVolume ? (v) => controller.save(value.copyWith(swipeSystemVolume: v)) : null,
            ),
            ListTile(
              title: const Text('Level indicator'),
              subtitle: const Text('While swiping for volume / brightness'),
              enabled: value.swipeVolume || value.swipeBrightness,
              trailing: AppDropdown<bool>(
                value: value.levelsAtSide,
                items: const [
                  DropdownMenuItem(value: false, child: Text('Centered pill')),
                  DropdownMenuItem(value: true, child: Text('Number at the side')),
                ],
                onChanged: value.swipeVolume || value.swipeBrightness
                    ? (v) => v == null ? null : controller.save(value.copyWith(levelsAtSide: v))
                    : null,
              ),
            ),
            SwitchListTile(
              title: const Text('Swipe for brightness'),
              subtitle: const Text('Up / down on the left side'),
              value: value.swipeBrightness,
              onChanged: (v) => controller.save(value.copyWith(swipeBrightness: v)),
            ),
          ],
        ];
      case SettingsCategory.home:
        return [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.view_agenda_outlined),
            title: const Text('Home rows'),
            subtitle: const Text('Reorder, hide, and add your own Jellyfin and Seerr rows'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/home'),
          ),
          const _Section('Top bar'),
          const HomeBarSection(),
          const _Section('Header'),
          HomeHeaderSection(isTv: device.isTv),
        ];
      case SettingsCategory.appearance:
        return [
          const SizedBox(height: 8),
          const AppearanceSection(),
          if (device.touch) ...[
            const _Section('Swiping episodes'),
            EpisodeSwipeSettings(
              dropdown: (value, onChanged) => AppDropdown<EpisodeSwipeAction>(
                value: value,
                items: [for (final a in EpisodeSwipeAction.values) DropdownMenuItem(value: a, child: Text(a.label))],
                onChanged: onChanged,
              ),
            ),
          ],
        ];
      case SettingsCategory.seerr:
        return const [SizedBox(height: 8), SeerrSettingsSection()];
      case SettingsCategory.anime:
        return const [SizedBox(height: 8), _AnimeSettings()];
      case SettingsCategory.troubleshooting:
        return [
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('App log'),
            subtitle: const Text('Everything the app did and what went wrong, by area: copy or save it for a bug report'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AppLogScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Playback log'),
            subtitle: const Text('What the player did lately, to copy into a bug report'),
            onTap: () => showDialog<void>(context: context, builder: (_) => const _PlaybackLogDialog()),
          ),
        ];
      case SettingsCategory.about:
        return const [SizedBox(height: 8), _About(), _Section('Updates'), UpdatesSection()];
    }
  }
}

/// The signed-in account, opening Accounts (switch, add, sign out, approve
/// Quick Connect).
class _AccountTile extends ConsumerWidget {
  const _AccountTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider).value;
    return ListTile(
      leading: CircleAvatar(
        child: Text(session == null || session.userName.isEmpty ? '?' : session.userName.characters.first.toUpperCase()),
      ),
      title: Text(session == null ? 'Not signed in' : session.userName),
      subtitle: Text(session == null
          ? 'Accounts'
          : '${session.serverName} · ${session.baseUrl.host}\nSwitch, add or sign out; approve a Quick Connect code'),
      isThreeLine: session != null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Whether the server answers now and still knows this sign-in.
          if (session != null)
            CheckConnectionButton(
              check: () => ConnectionChecks.of(ProviderScope.containerOf(context, listen: false))
                  .jellyfin([session.baseUrl], token: session.accessToken),
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => context.push('/accounts'),
    );
  }
}

class _About extends ConsumerWidget {
  const _About();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String? version;
    try {
      version = ref.read(clientInfoProvider).version;
    } on UnimplementedError {
      version = null; // tests without an install identity
    }
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('Kurage'),
          subtitle: Text(version == null ? 'Version unknown' : 'Version $version'),
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('Licences'),
          subtitle: const Text('Open-source software this app uses'),
          onTap: () => showLicensePage(context: context, applicationName: 'Kurage', applicationVersion: version),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.title,
    required this.hint,
    required this.value,
    required this.onSaved,
  });

  final String title;
  final String hint;
  final String value;
  final ValueChanged<String> onSaved;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(value),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () async {
        final controller = TextEditingController(text: value);
        final result = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(helperText: hint),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('Save'),
              ),
            ],
          ),
        );
        controller.dispose();
        final cleaned = result?.replaceAll(' ', '').toLowerCase();
        if (cleaned != null && cleaned.isNotEmpty) onSaved(cleaned);
      },
    );
  }
}

/// One row per player action with its keys; tap a row to change them.
class _PlayerControls extends ConsumerWidget {
  const _PlayerControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bindings = ref.watch(keybindingsProvider).value;
    if (bindings == null) return const SizedBox.shrink();
    final controller = ref.read(keybindingsProvider.notifier);

    return Column(
      children: [
        for (final action in PlayerAction.values)
          ListTile(
            title: Text(action.label),
            trailing: Text(
              bindings.keysFor(action).map(describeKey).join(', ').ifEmpty('None'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => _KeybindingDialog(action: action),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Reset controls to defaults'),
          onTap: controller.reset,
        ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// Lists an action's keys (removable) and adds whichever key is pressed next.
class _KeybindingDialog extends ConsumerStatefulWidget {
  const _KeybindingDialog({required this.action});

  final PlayerAction action;

  @override
  ConsumerState<_KeybindingDialog> createState() => _KeybindingDialogState();
}

class _KeybindingDialogState extends ConsumerState<_KeybindingDialog> {
  String? _note;

  static final _modifiers = {
    ...LogicalKeyboardKey.expandSynonyms({
      LogicalKeyboardKey.control,
      LogicalKeyboardKey.shift,
      LogicalKeyboardKey.alt,
      LogicalKeyboardKey.meta,
    }),
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.meta,
  };

  // Every key, Escape included, is a candidate binding, so this handler
  // claims all key presses; the dialog closes with its buttons.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (_modifiers.contains(event.logicalKey)) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final key = SingleActivator(
      event.logicalKey,
      control: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
    final current = ref.read(keybindingsProvider).value ?? Keybindings.defaults;
    final (updated, displaced) = current.bind(widget.action, key);
    ref.read(keybindingsProvider.notifier).save(updated);
    setState(() => _note = displaced == null
        ? null
        : '${describeKey(key)} was used for "${displaced.label}"; it now does this instead.');
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final bindings = ref.watch(keybindingsProvider).value ?? Keybindings.defaults;
    final keys = bindings.keysFor(widget.action);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        title: Text(widget.action.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Press a key (with Ctrl, Alt or Shift if you like) to add it.'),
            const SizedBox(height: 16),
            if (keys.isEmpty) const Text('No keys yet.'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final key in keys)
                  InputChip(
                    label: Text(describeKey(key)),
                    onDeleted: () => ref
                        .read(keybindingsProvider.notifier)
                        .save(bindings.unbind(widget.action, key)),
                    deleteButtonTooltipMessage: 'Remove',
                  ),
              ],
            ),
            if (_note != null) ...[
              const SizedBox(height: 16),
              Text(_note!, style: TextStyle(color: Theme.of(context).colorScheme.tertiary)),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

/// Private certificate authorities trusted on this device (added from the
/// connect screen), with a way to remove them.
class _TrustedCertificates extends ConsumerWidget {
  const _TrustedCertificates();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final certificates = ref.watch(trustedCertificatesProvider).value ?? const [];
    if (certificates.isEmpty) {
      return const ListTile(
        title: Text('None'),
        subtitle: Text(
          "Added when you trust a server's private certificate authority "
          'while connecting.',
        ),
      );
    }
    return Column(
      children: [
        for (final c in certificates)
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Text(c.name),
            subtitle: Text(c.fingerprint, style: const TextStyle(fontFamily: 'monospace')),
            trailing: IconButton(
              tooltip: 'Stop trusting',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => ref.read(trustedCertificatesProvider.notifier).remove(c),
            ),
          ),
      ],
    );
  }
}

class _AnimeSettings extends ConsumerWidget {
  const _AnimeSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(animeSettingsProvider).value;
    if (value == null) return const SizedBox.shrink();
    final controller = ref.read(animeSettingsProvider.notifier);
    final account = ref.watch(malAccountProvider).value;
    final clientId = ref.watch(malClientIdProvider).value ?? '';
    return Column(
      children: [
        if (account == null)
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Link MyAnimeList account'),
            subtitle: Text(clientId.isEmpty
                ? 'Needs a MyAnimeList client ID (below)'
                : 'Opens MyAnimeList in your browser to sign in'),
            enabled: clientId.isNotEmpty,
            onTap: () => _link(context, ref),
          )
        else
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Text('Linked as ${account.username}'),
            // The link is the Jellyfin user's, wherever they sign in.
            subtitle: Text('For ${ref.watch(sessionControllerProvider).value?.userName ?? 'this account'}, on every device'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CheckConnectionButton(
                  check: () => ConnectionChecks.of(ProviderScope.containerOf(context, listen: false))
                      .malAccount(() => ref.read(malAccountProvider.notifier).api().username()),
                ),
                TextButton(
                  onPressed: () => ref.read(malAccountProvider.notifier).unlink(),
                  child: const Text('Unlink'),
                ),
              ],
            ),
          ),
        SwitchListTile(
          title: const Text('Update my MyAnimeList as I watch'),
          subtitle: const Text(
            'Episode count, Watching and Completed with dates. Never lowers the count.',
          ),
          value: value.syncEnabled,
          onChanged: account == null ? null : (v) => controller.save(value.copyWith(syncEnabled: v)),
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Sync log'),
          onTap: () => showDialog<void>(context: context, builder: (_) => const _MalSyncLogDialog()),
        ),
        SwitchListTile(
          title: const Text('Use AniSkip when the server has no segments'),
          subtitle: const Text('Skip intro / credits from aniskip.com for matched anime'),
          value: value.useAniSkip,
          onChanged: (v) => controller.save(value.copyWith(useAniSkip: v)),
        ),
        ListTile(
          title: const Text('Skip markers'),
          subtitle: const Text('Which intro / credits timings to use first for anime'),
          trailing: AppDropdown<bool>(
            value: value.preferAniSkip,
            items: const [
              DropdownMenuItem(value: false, child: Text('Server first')),
              DropdownMenuItem(value: true, child: Text('AniSkip first')),
            ],
            onChanged: value.useAniSkip
                ? (v) => v == null ? null : controller.save(value.copyWith(preferAniSkip: v))
                : null,
          ),
        ),
        SwitchListTile(
          title: const Text('Show MyAnimeList scores'),
          subtitle: const Text('On posters and detail pages'),
          value: value.showScores,
          onChanged: (v) => controller.save(value.copyWith(showScores: v)),
        ),
        SwitchListTile(
          title: const Text('Episode ratings out of 10'),
          subtitle: const Text('MyAnimeList rates episodes 1–5; doubled to match show scores'),
          value: value.episodeScoresOutOf10,
          onChanged: value.showScores ? (v) => controller.save(value.copyWith(episodeScoresOutOf10: v)) : null,
        ),
        ListTile(
          title: const Text('Anime titles'),
          subtitle: const Text('Language for show and episode names across the app (from MyAnimeList)'),
          trailing: AppDropdown<TitleLanguage>(
            value: value.titleLanguage,
            items: [
              for (final l in TitleLanguage.values) DropdownMenuItem(value: l, child: Text(l.label)),
            ],
            onChanged: (l) => l == null ? null : controller.save(value.copyWith(titleLanguage: l)),
          ),
        ),
        // Built in: only to use another app's ID (advanced).
        ListTile(
          title: Text(builtInMalClientId.isEmpty ? 'MyAnimeList client ID' : 'Client ID (advanced)'),
          subtitle: Text(switch (clientId) {
            '' => 'Not set',
            _ when clientId == builtInMalClientId => 'Built in: nothing to set',
            _ => clientId,
          }),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () async {
            final entered = await MalClientIdController.entered();
            if (context.mounted) await _editClientId(context, ref, entered);
          },
        ),
      ],
    );
  }

  Future<void> _editClientId(BuildContext context, WidgetRef ref, String current) async {
    final text = TextEditingController(text: current);
    ConnectionCheck? tested;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('MyAnimeList client ID'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: text,
                autofocus: true,
                decoration: InputDecoration(
                  helperText: builtInMalClientId.isEmpty
                      ? 'From myanimelist.net/apiconfig (app type "other")'
                      : 'Empty: the built-in one. Or one from myanimelist.net/apiconfig (app type "other")',
                  helperMaxLines: 2,
                ),
              ),
              // The last Test's result (a toast sits behind the dialog on phones).
              if (tested case final t?) ConnectionCheckNote(t),
            ],
          ),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.network_check, size: 18),
              label: const Text('Test'),
              onPressed: () async {
                final r = await ConnectionChecks.of(ProviderScope.containerOf(context, listen: false))
                    .malClientId(text.text);
                if (context.mounted) setState(() => tested = r);
              },
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Save')),
          ],
        ),
      ),
    );
    text.dispose();
    if (result != null) await ref.read(malClientIdProvider.notifier).save(result);
  }

  Future<void> _link(BuildContext context, WidgetRef ref) async {
    showToast('Finish signing in in your browser…', id: 'mal-link');
    try {
      await ref.read(malAccountProvider.notifier).link();
      showToast('MyAnimeList linked.', id: 'mal-link');
    } on MalAuthException catch (e) {
      showToast(e.message, id: 'mal-link');
    }
  }
}

class _MalSyncLogDialog extends ConsumerStatefulWidget {
  const _MalSyncLogDialog();

  @override
  ConsumerState<_MalSyncLogDialog> createState() => _MalSyncLogDialogState();
}

class _MalSyncLogDialogState extends ConsumerState<_MalSyncLogDialog> {
  int? _pending;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshPending();
  }

  Future<void> _refreshPending() async {
    final q = await ref.read(malSyncServiceProvider).queue();
    if (mounted) setState(() => _pending = q.length);
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    await ref.read(malSyncServiceProvider).processQueue();
    await _refreshPending();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(malSyncLogProvider).value ?? const [];
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    return AlertDialog(
      title: const Text('MyAnimeList sync log'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(switch (_pending) {
              null => '',
              0 => 'Nothing waiting to be sent.',
              final n => '$n update(s) waiting to be sent.',
            }),
            const SizedBox(height: 8),
            if (log.isEmpty) const Text('No updates yet.'),
            for (final e in log)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  e.ok ? Icons.check_circle_outline : Icons.error_outline,
                  color: e.ok ? theme.colorScheme.primary : theme.colorScheme.error,
                ),
                title: Text(e.title),
                subtitle: Text(
                  '${e.message}\n${localizations.formatShortDate(e.at)} '
                  '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(e.at))}',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : _syncNow, child: const Text('Sync now')),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

class _PlaybackLogDialog extends StatelessWidget {
  const _PlaybackLogDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Playback log'),
        content: SizedBox(
          width: 640,
          child: ValueListenableBuilder<List<String>>(
            valueListenable: PlaybackLog.lines,
            builder: (_, lines, _) => lines.isEmpty
                ? const Text('Nothing yet: play something.')
                : SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(lines.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: PlaybackLog.text));
              showToast('Copied the playback log');
            },
            child: const Text('Copy'),
          ),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      );
}
