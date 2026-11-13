import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/jellyfin/trickplay.dart';
import '../../library/widgets/item_image.dart';

/// The frame at [time]: its cell of the trickplay tile sheet, scaled to
/// [width]. Tile sheets are cached like other images, so moving along the
/// bar only fetches a new sheet every [Trickplay.perTile] frames.
class TrickplayThumbnail extends ConsumerWidget {
  const TrickplayThumbnail({
    super.key,
    required this.trickplay,
    required this.time,
    required this.tileUrl,
    this.width = 208,
  });

  final Trickplay trickplay;
  final Duration time;
  final Uri Function(int tile) tileUrl;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = trickplay;
    final scale = width / t.width;
    final height = t.height * scale;
    final frame = t.frameAt(time);
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: Colors.black,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: Transform.translate(
              offset: Offset(-frame.column * width, -frame.row * height),
              child: SizedBox(
                width: t.tileWidth * width,
                height: t.tileHeight * height,
                child: ref.watch(networkImageBuilderProvider)(
                  tileUrl(frame.tile).toString(),
                  fit: BoxFit.fill,
                  alignment: Alignment.topLeft,
                  fallback: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
