import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log/app_log.dart';
import 'theme_choice.dart';

/// The parts of the app a theme can restyle, by name (its `components`).
abstract final class Slots {
  /// The page behind Home and show pages (Depth: "glow").
  static const backdrop = 'app.backdrop';
  static const homeTopBar = 'home.topBar';
  static const homeHero = 'home.hero';
  static const continueWatching = 'home.row.continueWatching';
  static const nextUp = 'home.row.nextUp';
  static const libraries = 'home.row.libraries';
  static const recentlyAdded = 'home.row.recentlyAdded';

  /// Rows made in the Home editor from a library filter.
  static const libraryRow = 'home.row.library';

  /// Seerr's rows (trending, discover, requests) and Home editor rows made
  /// from a Seerr filter.
  static const seerrRow = 'home.row.seerr';

  /// This week: what airs and comes out, Monday to Sunday.
  static const thisWeek = 'home.row.thisWeek';
  static const genres = 'home.row.genres';

  /// Around each section of Home, however it's drawn.
  static const homeSection = 'home.section';

  /// A series, film or episode's own page.
  static const itemPage = 'item.page';

  static const all = [
    backdrop,
    homeTopBar,
    homeHero,
    continueWatching,
    nextUp,
    libraries,
    recentlyAdded,
    libraryRow,
    seerrRow,
    thisWeek,
    genres,
    homeSection,
    itemPage,
  ];
}

/// How the active theme draws one slot: its [variant] and parameters.
/// Without an entry in the theme, the variant is `classic`.
class ComponentStyle {
  const ComponentStyle(this.variant, [this.params = const {}]);

  static const classic = ComponentStyle('classic');

  final String variant;
  final Map<String, Object?> params;

  /// A parameter, or [fallback] when it's missing or of another type (a
  /// theme file can say anything).
  T param<T>(String key, T fallback) {
    final v = params[key];
    if (v is T) return v;
    if (fallback is double && v is num) return v.toDouble() as T;
    return fallback;
  }

  @override
  bool operator ==(Object other) => other is ComponentStyle && other.variant == variant && _same(other.params, params);

  @override
  int get hashCode => Object.hash(variant, Object.hashAllUnordered(params.keys));

  static bool _same(Map<String, Object?> a, Map<String, Object?> b) =>
      a.length == b.length && a.entries.every((e) => b.containsKey(e.key) && b[e.key] == e.value);
}

/// The active theme's style for [slot] (on this device).
final componentStyleProvider = Provider.family<ComponentStyle, String>((ref, slot) {
  final c = ref.watch(activeThemeProvider.select((t) => t.components[slot]));
  if (c == null) return ComponentStyle.classic;
  final variant = c['variant'];
  return ComponentStyle(variant is String && variant.isNotEmpty ? variant : 'classic', {...c}..remove('variant'));
});

/// The variants one slot can be drawn with, by name; `classic` always
/// exists. [D] is what the slot shows (a row's items and actions, …).
class Variants<D> {
  Variants(this.slot, {required Widget Function(BuildContext context, D data, ComponentStyle style) classic})
      : _builders = {'classic': classic};

  final String slot;
  final Map<String, Widget Function(BuildContext context, D data, ComponentStyle style)> _builders;
  final _warned = <String>{};

  /// Adds a variant (a theme's new style for this slot).
  void register(String name, Widget Function(BuildContext context, D data, ComponentStyle style) builder) =>
      _builders[name] = builder;

  @visibleForTesting
  void unregister(String name) {
    if (name != 'classic') _builders.remove(name);
  }

  Iterable<String> get names => _builders.keys;

  /// [data] drawn in [style]; a variant this app doesn't have falls back to
  /// classic (a theme made for a newer app).
  Widget build(BuildContext context, D data, ComponentStyle style) {
    final builder = _builders[style.variant];
    if (builder != null) return builder(context, data, style);
    if (_warned.add(style.variant)) {
      AppLog.warning(LogArea.app, 'Theme: no "${style.variant}" style for $slot here; using classic');
    }
    return _builders['classic']!(context, data, ComponentStyle.classic);
  }
}
