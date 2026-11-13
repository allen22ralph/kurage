import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/toast.dart';
import '../playback_log.dart';
import '../../../core/jellyfin/items.dart';
import '../../../core/jellyfin/playback_api.dart';
import '../../library/widgets/item_image.dart';
import '../playback_controller.dart';

/// "Skip intro" button and "Up next" card, drawn above the video.
class PlayerOverlays extends StatelessWidget {
  const PlayerOverlays({super.key, required this.controller});

  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final segment = controller.activeSegment;
    final next = controller.nextEpisode;
    final countdown = controller.upNextCountdown;
    final notice = controller.chapterNotice;

    return Positioned.fill(
      child: Stack(
        children: [
          // Brief "Part B · 3/5" after a chapter jump, visible even with the
          // controls hidden; below the top bar.
          if (notice != null)
            Positioned(
              top: 72,
              left: 24,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Text(
                      '${controller.chapterLabel(notice)} · '
                      '${notice + 1}/${controller.chapters.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(child: _corner(segment, next, countdown)),
        ],
      ),
    );
  }

  Widget _corner(MediaSegment? segment, BaseItem? next, int? countdown) {
    return Padding(
        // Clear of the seek bar and button bar.
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
        child: Align(
          alignment: Alignment.bottomRight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (next != null && countdown != null)
                UpNextCard(
                  episode: next,
                  secondsLeft: countdown,
                  onPlay: controller.playNext,
                  onDismiss: controller.dismissUpNext,
                )
              else if (segment != null && _skipLabel(segment.type) != null)
                Tooltip(
                  // Where the timings came from (hover on desktop).
                  message: controller.segmentsFromFallback ? 'Timings from AniSkip' : 'Timings from the server',
                  child: FilledButton.tonalIcon(
                    // Focused so a TV remote's OK button skips straight away.
                    autofocus: true,
                    onPressed: controller.skipSegment,
                    icon: const Icon(Icons.fast_forward),
                    label: Text(_skipLabel(segment.type)!),
                  ),
                ),
            ],
          ),
        ),
      );
  }

  static String? _skipLabel(SegmentType type) => switch (type) {
        SegmentType.intro => 'Skip intro',
        SegmentType.recap => 'Skip recap',
        SegmentType.outro => 'Skip credits',
        SegmentType.preview => 'Skip preview',
        SegmentType.commercial => 'Skip',
        SegmentType.unknown => null,
      };
}

class UpNextCard extends StatelessWidget {
  const UpNextCard({
    super.key,
    required this.episode,
    required this.secondsLeft,
    required this.onPlay,
    required this.onDismiss,
  });

  final BaseItem episode;
  final int secondsLeft;
  final VoidCallback onPlay;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: Colors.black.withValues(alpha: 0.85),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 160,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ItemImage(image: episode.landscapeImage, maxWidth: 160),
                ),
              ),
            ),
            const SizedBox(width: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Up next in $secondsLeft', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Text(
                    [?episode.episodeLabel, episode.name].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: onPlay,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play now'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(onPressed: onDismiss, child: const Text('Cancel')),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerErrorPanel extends StatelessWidget {
  const PlayerErrorPanel({super.key, required this.message, required this.onBack, this.details, this.onRetry});

  final String message;
  final VoidCallback onBack;

  /// What was playing, where and how (copied with Copy details).
  final String? details;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = this.details;
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
                if (details != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    details.split('\n').skip(1).join('\n'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                ],
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    if (onRetry != null)
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    if (details != null)
                      OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: '$details\n\nRecent playback log:\n${PlaybackLog.text}'));
                          showToast('Copied: paste it into your report');
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy details'),
                      ),
                    OutlinedButton(autofocus: onRetry == null, onPressed: onBack, child: const Text('Back')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
