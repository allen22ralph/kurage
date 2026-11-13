import 'package:flutter/material.dart';

import 'theme_spec.dart';

/// The active theme's values that Material's own theme has no place for
/// (star and status colours, glass, radii, motion), on [ThemeData].
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens(this.tokens);

  final ThemeTokens tokens;

  @override
  AppTokens copyWith({ThemeTokens? tokens}) => AppTokens(tokens ?? this.tokens);

  // Theme changes swap straight over (no blend between two themes).
  @override
  AppTokens lerp(AppTokens? other, double t) => t < 0.5 || other == null ? this : other;
}

extension AppTokensOf on BuildContext {
  /// The active theme's values; Classic's outside the app's own theme
  /// (e.g. a widget tested on its own).
  ThemeTokens get tokens => Theme.of(this).extension<AppTokens>()?.tokens ?? classicTheme.tokens;
}
