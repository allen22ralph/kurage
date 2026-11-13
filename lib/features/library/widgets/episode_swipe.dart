import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/jellyfin/items.dart';
import '../../../theme/app_tokens.dart';
import '../../downloads/downloads.dart';
import '../../downloads/downloads_screen.dart';
import '../../settings/appearance.dart';
import 'card_actions.dart';

/// What swiping an episode's row does (Settings > Appearance).
enum EpisodeSwipeAction {
  none('Nothing'),
  watched('Watched / unwatched'),
  favorite('Like / unlike'),
  download('Download / delete');

  const EpisodeSwipeAction(this.label);

  final String label;

  static EpisodeSwipeAction named(String? name, EpisodeSwipeAction otherwise) =>
      values.where((a) => a.name == name).firstOrNull ?? otherwise;
}

/// What each way of swiping does, kept on this device.
typedef EpisodeSwipes = ({EpisodeSwipeAction left, EpisodeSwipeAction right});

final episodeSwipesProvider = AsyncNotifierProvider<EpisodeSwipesController, EpisodeSwipes>(EpisodeSwipesController.new);

class EpisodeSwipesController extends AsyncNotifier<EpisodeSwipes> {
  static const _left = 'library.swipeLeft';
  static const _right = 'library.swipeRight';

  @override
  Future<EpisodeSwipes> build() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      left: EpisodeSwipeAction.named(prefs.getString(_left), EpisodeSwipeAction.watched),
      right: EpisodeSwipeAction.named(prefs.getString(_right), EpisodeSwipeAction.none),
    );
  }

  Future<void> save(EpisodeSwipes swipes) async {
    state = AsyncData(swipes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_left, swipes.left.name);
    await prefs.setString(_right, swipes.right.name);
  }
}

/// An episode's row that can be swiped, by touch, in any theme. The row follows
/// the finger, ticks at the point of no return and, let go past it, does what
/// that way is set to do and springs back, staying in the list.
class EpisodeSwipe extends ConsumerStatefulWidget {
  const EpisodeSwipe({
    super.key,
    required this.episode,
    required this.played,
    required this.onWatched,
    required this.enabled,
    required this.child,
  });

  final BaseItem episode;

  /// Watched, as just marked (the episode itself follows from the server).
  final bool played;

  /// Marks it the other way; null while that's still being saved.
  final VoidCallback? onWatched;

  /// Off while selecting.
  final bool enabled;
  final Widget child;

  @override
  ConsumerState<EpisodeSwipe> createState() => _EpisodeSwipeState();
}

class _EpisodeSwipeState extends ConsumerState<EpisodeSwipe> with SingleTickerProviderStateMixin {
  static const _reach = 96.0;

  late final AnimationController _offset = AnimationController.unbounded(vsync: this);

  /// How far the finger has come: negative to the left.
  double _pulled = 0;
  bool _armed = false;
  EpisodeSwipeAction _action = EpisodeSwipeAction.none;

  /// What letting go would do, kept as the row springs back (by then that
  /// will have changed).
  IconData _icon = Icons.check_circle;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  EpisodeSwipeAction _actionFor({required bool left}) {
    final swipes = ref.read(episodeSwipesProvider).value;
    if (swipes == null || !widget.enabled) return EpisodeSwipeAction.none;
    final action = left ? swipes.left : swipes.right;
    return switch (action) {
      EpisodeSwipeAction.watched when widget.onWatched == null => EpisodeSwipeAction.none,
      EpisodeSwipeAction.download when !canDownload(widget.episode) => EpisodeSwipeAction.none,
      _ => action,
    };
  }

  IconData _iconOf(EpisodeSwipeAction action) => switch (action) {
        EpisodeSwipeAction.none => Icons.block,
        EpisodeSwipeAction.watched => widget.played ? Icons.remove_done_rounded : Icons.check_circle,
        EpisodeSwipeAction.favorite => widget.episode.userData.isFavorite ? Icons.heart_broken_outlined : Icons.favorite,
        EpisodeSwipeAction.download =>
          ref.read(downloadsProvider).value?[widget.episode.id] == null ? Icons.download_outlined : Icons.delete_outline,
      };

  void _start(DragStartDetails _) {
    _offset.stop();
    _pulled = _offset.value;
  }

  void _update(DragUpdateDetails d) {
    final pulled = _pulled + d.primaryDelta!;
    final action = _actionFor(left: pulled < 0);
    if (action == EpisodeSwipeAction.none) {
      _pulled = 0;
      _armed = false;
      _offset.value = 0;
      return;
    }
    _pulled = pulled;
    _action = action;
    _icon = _iconOf(action);
    // Past the point of no return it follows the finger less.
    final far = pulled.abs();
    _offset.value = pulled.sign * (far <= _reach ? far : _reach + (far - _reach) * 0.35);
    final armed = far >= _reach;
    if (armed && !_armed) HapticFeedback.mediumImpact();
    _armed = armed;
  }

  void _end() {
    if (_armed) _run(_action);
    _armed = false;
    _pulled = 0;
    if (animationsOn(context)) {
      _offset.animateTo(0, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    } else {
      _offset.value = 0;
    }
  }

  void _run(EpisodeSwipeAction action) {
    final episode = widget.episode;
    switch (action) {
      case EpisodeSwipeAction.none:
        break;
      case EpisodeSwipeAction.watched:
        widget.onWatched?.call();
      case EpisodeSwipeAction.favorite:
        CardActions(context).setFavorite(episode, !episode.userData.isFavorite);
      case EpisodeSwipeAction.download:
        if (ref.read(downloadsProvider).value?[episode.id] == null) {
          startDownload(context, episode);
        } else {
          confirmDeleteDownload(context, ref, episode);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Known by the first swipe.
    ref.watch(episodeSwipesProvider);
    final theme = Theme.of(context);
    final tint = context.tokens.accent2 ?? theme.colorScheme.primary;
    return GestureDetector(
      supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus},
      onHorizontalDragStart: _start,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: (_) => _end(),
      onHorizontalDragCancel: () {
        _armed = false;
        _end();
      },
      child: AnimatedBuilder(
        animation: _offset,
        child: widget.child,
        builder: (context, child) {
          final moved = _offset.value;
          final pull = math.min(1.0, moved.abs() / _reach);
          return Stack(
            children: [
              if (pull > 0)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: ColoredBox(
                      color: tint.withValues(alpha: pull == 1 ? 0.3 : 0.1),
                      child: Align(
                        alignment: moved < 0 ? Alignment.centerRight : Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          child: Opacity(opacity: pull, child: Icon(_icon, color: tint, size: 24)),
                        ),
                      ),
                    ),
                  ),
                ),
              Transform.translate(offset: Offset(moved, 0), child: child),
            ],
          );
        },
      ),
    );
  }
}

/// Settings: what each way of swiping an episode does.
class EpisodeSwipeSettings extends ConsumerWidget {
  const EpisodeSwipeSettings({super.key, required this.dropdown});

  /// The settings' own dropdown, around these choices.
  final Widget Function(EpisodeSwipeAction value, ValueChanged<EpisodeSwipeAction?> onChanged) dropdown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final swipes = ref.watch(episodeSwipesProvider).value;
    if (swipes == null) return const SizedBox.shrink();
    final controller = ref.read(episodeSwipesProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: const Text('Swipe left'),
          trailing: dropdown(swipes.left, (v) => v == null ? null : controller.save((left: v, right: swipes.right))),
        ),
        ListTile(
          title: const Text('Swipe right'),
          trailing: dropdown(swipes.right, (v) => v == null ? null : controller.save((left: swipes.left, right: v))),
        ),
      ],
    );
  }
}
