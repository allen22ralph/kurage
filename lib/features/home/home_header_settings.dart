import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app/app_dropdown.dart';
import '../settings/appearance.dart';
import '../../theme/theme_choice.dart';

/// What the header at the top of Home is.
enum HeaderStyle {
  trailers('Trailers', "The show's own trailer plays behind it (the backdrop when it has none)"),
  banners('Banners', 'Still backdrops of shows on your server, one after another'),
  off('Off', 'No header: Home starts with its rows');

  const HeaderStyle(this.label, this.description);

  final String label;
  final String description;
}

/// What Home's header features (#100).
enum HeaderFeatured {
  mix('A mix', 'What you\'re watching, what\'s new, and random picks'),
  continueWatching('Continue watching', 'Shows and movies you\'re partway through or up next in'),
  recentlyAdded('Recently added', 'The newest in your libraries'),
  random('Random picks', 'Anything from your libraries, at random');

  const HeaderFeatured(this.label, this.description);

  final String label;
  final String description;
}

/// How long the header plays each trailer before moving on.
enum TrailerLength {
  standard('Theme default'),
  s15('15 seconds', 15),
  s30('30 seconds', 30),
  s45('45 seconds', 45),
  s60('1 minute', 60),
  s90('1 minute 30', 90),
  full('Full trailer');

  const TrailerLength(this.label, [this.seconds]);

  final String label;
  final int? seconds;

  /// How long a trailer of [length] (null until known) plays. [standard] is
  /// the theme's own limit. The whole of it, however long, when it's [full].
  Duration playFor(Duration standard, Duration? length) {
    if (this == TrailerLength.full) return length ?? const Duration(hours: 1);
    final most = seconds == null ? standard : Duration(seconds: seconds!);
    return length == null || most < length ? most : length;
  }
}

class HomeHeaderSettings {
  const HomeHeaderSettings({
    this.style = HeaderStyle.trailers,
    this.bannerPan = true,
    this.featured = HeaderFeatured.mix,
    this.muted = true,
    this.volume = 60,
    this.trailersOnMobileData = false,
    this.previews = true,
    this.trailerLength = TrailerLength.standard,
  });

  final HeaderStyle style;

  /// Banners: pan slowly across the backdrop (off: perfectly still).
  final bool bannerPan;
  final HeaderFeatured featured;

  bool get enabled => style != HeaderStyle.off;

  /// The show's own trailer plays behind the header (when it has one).
  bool get trailers => style == HeaderStyle.trailers;

  /// The backdrop moves: always behind a trailer-less show in Trailers;
  /// as chosen for Banners.
  bool get pan => style == HeaderStyle.trailers || bannerPan;

  /// Trailers start muted (the header's speaker button unmutes).
  final bool muted;

  /// Trailer volume, 0–100.
  final double volume;

  /// Phones: the header's trailers and Home's previews on mobile data too
  /// (off: only on Wi-Fi / ethernet).
  final bool trailersOnMobileData;

  /// Home's rows play a muted clip of what's in focus (Depth).
  final bool previews;

  final TrailerLength trailerLength;

  HomeHeaderSettings copyWith({
    HeaderStyle? style,
    bool? bannerPan,
    HeaderFeatured? featured,
    bool? muted,
    double? volume,
    bool? trailersOnMobileData,
    bool? previews,
    TrailerLength? trailerLength,
  }) =>
      HomeHeaderSettings(
        style: style ?? this.style,
        bannerPan: bannerPan ?? this.bannerPan,
        featured: featured ?? this.featured,
        muted: muted ?? this.muted,
        volume: volume ?? this.volume,
        trailersOnMobileData: trailersOnMobileData ?? this.trailersOnMobileData,
        previews: previews ?? this.previews,
        trailerLength: trailerLength ?? this.trailerLength,
      );
}

final homeHeaderSettingsProvider =
    AsyncNotifierProvider<HomeHeaderSettingsController, HomeHeaderSettings>(HomeHeaderSettingsController.new);

class HomeHeaderSettingsController extends AsyncNotifier<HomeHeaderSettings> {
  static const _prefix = 'homeHeader.';

  @override
  Future<HomeHeaderSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    const d = HomeHeaderSettings();
    // Before the style setting: header on / off and trailers on / off.
    final oldStyle = switch ((prefs.getBool('${_prefix}enabled'), prefs.getBool('${_prefix}trailers'))) {
      (false, _) => HeaderStyle.off,
      (_, false) => HeaderStyle.banners,
      _ => d.style,
    };
    return HomeHeaderSettings(
      style: HeaderStyle.values.where((s) => s.name == prefs.getString('${_prefix}style')).firstOrNull ?? oldStyle,
      bannerPan: prefs.getBool('${_prefix}bannerPan') ?? d.bannerPan,
      featured: HeaderFeatured.values.where((f) => f.name == prefs.getString('${_prefix}featured')).firstOrNull ??
          d.featured,
      muted: prefs.getBool('${_prefix}muted') ?? d.muted,
      volume: prefs.getDouble('${_prefix}volume') ?? d.volume,
      trailersOnMobileData: prefs.getBool('${_prefix}trailersOnMobileData') ?? d.trailersOnMobileData,
      previews: prefs.getBool('${_prefix}previews') ?? d.previews,
      trailerLength: TrailerLength.values.where((l) => l.name == prefs.getString('${_prefix}trailerLength')).firstOrNull ??
          d.trailerLength,
    );
  }

  Future<void> save(HomeHeaderSettings settings) async {
    await future.catchError((Object _) => const HomeHeaderSettings());
    state = AsyncData(settings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}style', settings.style.name);
    await prefs.setBool('${_prefix}bannerPan', settings.bannerPan);
    await prefs.setString('${_prefix}featured', settings.featured.name);
    await prefs.setBool('${_prefix}muted', settings.muted);
    await prefs.setDouble('${_prefix}volume', settings.volume);
    await prefs.setBool('${_prefix}trailersOnMobileData', settings.trailersOnMobileData);
    await prefs.setBool('${_prefix}previews', settings.previews);
    await prefs.setString('${_prefix}trailerLength', settings.trailerLength.name);
  }
}

/// Settings > Home > Header.
class HomeHeaderSection extends ConsumerWidget {
  const HomeHeaderSection({super.key, required this.isTv});

  final bool isTv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(homeHeaderSettingsProvider).value ?? const HomeHeaderSettings();
    final controller = ref.read(homeHeaderSettingsProvider.notifier);
    final on = value.enabled;
    final trailers = value.trailers;
    // What Effects turns off, in themes that follow it: greyed, saying why.
    ref.watch(appearanceProvider);
    final themed = ref.watch(activeThemeProvider).components.isNotEmpty;
    final effects = effectsOf(context);
    final trailersOff = themed && !effects.playsTrailers;
    final previewsOff = themed && !effects.playsPreviews;
    const offOnLite = 'Off while Appearance > Effects is Lite';
    return Column(
      children: [
        ListTile(
          title: const Text('Header'),
          subtitle: Text(value.style.description),
          trailing: SegmentedButton<HeaderStyle>(
            showSelectedIcon: false,
            segments: [for (final s in HeaderStyle.values) ButtonSegment(value: s, label: Text(s.label))],
            selected: {value.style},
            onSelectionChanged: (s) => controller.save(value.copyWith(style: s.first)),
          ),
        ),
        ListTile(
          enabled: on,
          title: const Text('Featured'),
          subtitle: Text(value.featured.description),
          trailing: AppDropdown<HeaderFeatured>(
            value: value.featured,
            underline: const SizedBox.shrink(),
            items: [for (final f in HeaderFeatured.values) DropdownMenuItem(value: f, child: Text(f.label))],
            onChanged: on ? (f) => f == null ? null : controller.save(value.copyWith(featured: f)) : null,
          ),
        ),
        if (value.style == HeaderStyle.banners)
          SwitchListTile(
            title: const Text('Slow pan'),
            subtitle: Text(themed ? 'Not in this theme' : 'The backdrop drifts slowly. Off: perfectly still'),
            value: value.bannerPan,
            onChanged: themed ? null : (v) => controller.save(value.copyWith(bannerPan: v)),
          ),
        // Trailer options only for Trailers.
        if (trailers) ...[
        SwitchListTile(
          title: const Text('Trailers start muted'),
          subtitle: Text(trailersOff ? offOnLite : 'The speaker button on the header turns the sound on'),
          value: value.muted,
          onChanged: trailersOff ? null : (v) => controller.save(value.copyWith(muted: v)),
        ),
        ListTile(
          enabled: !trailersOff,
          title: const Text('Trailer volume'),
          subtitle: Slider(
            value: value.volume,
            max: 100,
            divisions: 20,
            label: '${value.volume.round()} %',
            onChanged: trailersOff ? null : (v) => controller.save(value.copyWith(volume: v)),
          ),
        ),
        ListTile(
          enabled: !trailersOff,
          title: const Text('Play each trailer for'),
          subtitle: Text(trailersOff ? offOnLite : 'Then on to the next show. A shorter trailer ends sooner'),
          trailing: AppDropdown<TrailerLength>(
            value: value.trailerLength,
            underline: const SizedBox.shrink(),
            items: [for (final l in TrailerLength.values) DropdownMenuItem(value: l, child: Text(l.label))],
            onChanged: trailersOff ? null : (l) => l == null ? null : controller.save(value.copyWith(trailerLength: l)),
          ),
        ),
        // Phones only: a TV or desktop isn't on mobile data. For previews
        // too, so it's there whatever the header shows.
        if (Platform.isAndroid && !isTv)
          SwitchListTile(
            title: const Text('Trailers and previews on mobile data'),
            subtitle: Text(trailersOff ? offOnLite : "The header's trailers and Home's episode previews. Off: only on Wi-Fi"),
            value: value.trailersOnMobileData,
            onChanged: trailersOff ? null : (v) => controller.save(value.copyWith(trailersOnMobileData: v)),
          ),
        ],
        // Whatever the header shows; Classic has no previews.
        if (ref.watch(activeThemeProvider).components.isNotEmpty)
          SwitchListTile(
            title: const Text('Previews in rows'),
            subtitle: Text(previewsOff ? 'Only while Appearance > Effects is Full' : 'Continue watching, Next up and expanding rows play a muted clip. Only with Effects on Full'),
            value: value.previews,
            onChanged: previewsOff ? null : (v) => controller.save(value.copyWith(previews: v)),
          ),
      ],
    );
  }
}
