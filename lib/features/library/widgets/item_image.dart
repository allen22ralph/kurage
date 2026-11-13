import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/jellyfin/items.dart';

/// Builds the widget that downloads and shows an image URL.
///
/// Overridden in tests, where the disk cache's native plugins don't exist.
final networkImageBuilderProvider = Provider<NetworkImageBuilder>(
  (ref) => (url, {required fit, required alignment, required fallback}) =>
      CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        alignment: alignment,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => const _Blank(),
        errorWidget: (_, _, _) => fallback,
      ),
);

typedef NetworkImageBuilder = Widget Function(
  String url, {
  required BoxFit fit,
  required Alignment alignment,
  required Widget fallback,
});

/// Loads a Jellyfin image, sized server-side to [maxWidth] physical pixels.
///
/// Shows [placeholder] (or a neutral box) when there is no image or it fails.
class ItemImage extends ConsumerWidget {
  const ItemImage({
    super.key,
    required this.image,
    required this.maxWidth,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.placeholder,
  });

  final ImageRef? image;

  /// Logical width the image is displayed at.
  final double maxWidth;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = placeholder ?? const _Blank();
    final image = this.image;
    if (image == null) return fallback;

    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Round up to a step so nearby sizes share cache entries.
    final pixels = ((maxWidth * dpr) / 100).ceil() * 100;
    final url = ref
        .watch(signedInApiProvider)
        .imageUrl(image.itemId, image.type, tag: image.tag, maxWidth: pixels)
        .toString();

    return ref.watch(networkImageBuilderProvider)(
      url,
      fit: fit,
      alignment: alignment,
      fallback: fallback,
    );
  }
}

class _Blank extends StatelessWidget {
  const _Blank();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }
}
