import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/appearance.dart';

enum FormFactor { phone, desktop, tv }

/// True on Android TV / Google TV. Detected at startup in `main()`.
final isTvProvider = Provider<bool>((ref) => false);

/// Sizes that scale with the form factor, so one layout works on a phone,
/// a desktop window, and a TV viewed from across the room.
class LayoutSpec {
  const LayoutSpec(this.formFactor, {this.cardScale = 1});

  final FormFactor formFactor;

  /// Settings > Appearance > Card size.
  final double cardScale;

  static FormFactor formFactorOf(BuildContext context, {required bool isTv}) {
    if (isTv) return FormFactor.tv;
    return MediaQuery.sizeOf(context).shortestSide < 600
        ? FormFactor.phone
        : FormFactor.desktop;
  }

  /// Width of a portrait (2:3) poster card.
  double get posterWidth => cardScale * switch (formFactor) {
        FormFactor.phone => 112,
        FormFactor.desktop => 160,
        FormFactor.tv => 176,
      };

  /// Width of a landscape (16:9) card.
  double get landscapeWidth => cardScale * switch (formFactor) {
        FormFactor.phone => 220,
        FormFactor.desktop => 300,
        FormFactor.tv => 320,
      };

  /// Horizontal page padding.
  double get gutter => switch (formFactor) {
        FormFactor.phone => 16,
        FormFactor.desktop => 32,
        FormFactor.tv => 48,
      };
}

extension LayoutContext on BuildContext {
  /// Layout sizes for this screen. Requires a [ProviderScope] above.
  LayoutSpec get layout {
    final container = ProviderScope.containerOf(this, listen: false);
    final isTv = container.read(isTvProvider);
    final scale = container.read(appearanceProvider).value?.cardSize.scale ?? 1;
    return LayoutSpec(LayoutSpec.formFactorOf(this, isTv: isTv), cardScale: scale);
  }
}

/// The status bar's real height. Inside a [Scaffold]'s body, MediaQuery's
/// padding and viewPadding can both have had it taken out; the view itself
/// still says. The tallest seen, for each way up: a page that hides the bar as
/// it scrolls keeps its layout, rather than jumping when it next builds.
double statusBarHeight(BuildContext context) {
  final view = MediaQueryData.fromView(View.of(context));
  final tallest = math.max(_statusBars[view.orientation] ?? 0, view.viewPadding.top);
  return _statusBars[view.orientation] = tallest;
}

final _statusBars = <Orientation, double>{};
