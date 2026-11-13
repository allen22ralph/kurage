import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

/// Rows picked for a batch action (Downloads, a season's episodes): long
/// press or right-click > Select starts it; then a tap toggles, Ctrl+click
/// toggles, Shift+click selects a range.
class Selection extends ChangeNotifier {
  final ids = <String>{};
  String? _anchor;

  bool get active => ids.isNotEmpty;
  bool contains(String id) => ids.contains(id);

  void toggle(String id) {
    if (!ids.remove(id)) ids.add(id);
    _anchor = id;
    notifyListeners();
  }

  /// Everything from the last row picked to [id], in [order].
  void range(List<String> order, String id) {
    final from = order.indexOf(_anchor ?? id);
    final to = order.indexOf(id);
    if (from < 0 || to < 0) return toggle(id);
    ids.addAll(order.sublist(from < to ? from : to, (from < to ? to : from) + 1));
    _anchor = id;
    notifyListeners();
  }

  /// Selects (or, [on] false, clears) all of [some].
  void setAll(Iterable<String> some, {bool on = true}) {
    on ? ids.addAll(some) : ids.removeAll(some);
    notifyListeners();
  }

  void clear() {
    ids.clear();
    _anchor = null;
    notifyListeners();
  }

  /// A click on a row: Shift / Ctrl, or any click while selecting, picks.
  /// False when it's an ordinary click (open / play).
  bool tap(List<String> order, String id) {
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed && (_anchor != null || active)) {
      range(order, id);
    } else if (keys.isControlPressed || keys.isMetaPressed || active) {
      toggle(id);
    } else {
      return false;
    }
    return true;
  }
}

/// The bar over a list while selecting: how many, and the actions.
class SelectionBar extends StatelessWidget implements PreferredSizeWidget {
  const SelectionBar({
    super.key,
    required this.selection,
    required this.label,
    required this.actions,
    this.onSelectAll,
  });

  final Selection selection;

  /// "12 selected · 14.8 GB".
  final String label;
  final List<Widget> actions;
  final VoidCallback? onSelectAll;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => AppBar(
    leading: IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: selection.clear),
    title: Text(label),
    actions: [
      if (onSelectAll != null)
        IconButton(tooltip: 'Select all', icon: const Icon(Icons.select_all), onPressed: onSelectAll),
      ...actions,
      const SizedBox(width: 8),
    ],
  );
}

/// Ctrl+A selects all, Esc stops selecting, while [child] has focus.
class SelectionShortcuts extends StatelessWidget {
  const SelectionShortcuts({
    super.key,
    required this.selection,
    required this.selectAll,
    required this.child,
    this.autofocus = false,
  });

  final Selection selection;
  final VoidCallback selectAll;
  final Widget child;

  /// Take the keyboard on opening (a page that is all list, like Downloads;
  /// not a show page, whose Play button has it).
  final bool autofocus;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyA, control: true): selectAll,
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (selection.active) selection.clear();
      },
    },
    child: Focus(autofocus: autofocus, child: child),
  );
}

/// The selection's actions in a floating pill at the bottom of the screen,
/// over [child] (a part of a scrolling page): it slides away while the page
/// scrolls down (to pick more) and back as soon as it scrolls up, or when
/// the selection changes. Always shown on a TV (the remote scrolls the page
/// as it moves).
class FloatingSelectionBar extends StatefulWidget {
  const FloatingSelectionBar({
    super.key,
    required this.selection,
    required this.label,
    required this.actions,
    required this.child,
    this.alwaysShown = false,
    this.controller,
  });

  final Selection selection;

  /// The list's controller, when [child] is the whole list (else the
  /// scrolling page around [child] is followed).
  final ScrollController? controller;

  /// "3 selected".
  final String label;
  final List<Widget> actions;
  final Widget child;
  final bool alwaysShown;

  @override
  State<FloatingSelectionBar> createState() => _FloatingSelectionBarState();
}

class _FloatingSelectionBarState extends State<FloatingSelectionBar> {
  final _portal = OverlayPortalController();
  ScrollPosition? _position;
  bool _shown = true;

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_onSelection);
    widget.controller?.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSelection());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.controller != null) return;
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _position) {
      _position?.removeListener(_onScroll);
      _position = position?..addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelection);
    widget.controller?.removeListener(_onScroll);
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  void _onSelection() {
    if (!mounted) return;
    if (widget.selection.active) {
      _portal.show();
      setState(() => _shown = true);
    } else {
      _portal.hide();
    }
  }

  void _onScroll() {
    final c = widget.controller;
    final p = c != null && c.hasClients ? c.position : _position;
    if (p == null || widget.alwaysShown) return;
    final atEnd = p.pixels >= p.maxScrollExtent - 4;
    final shown = switch (p.userScrollDirection) {
      ScrollDirection.reverse => atEnd, // scrolling down
      ScrollDirection.forward => true, // scrolling up
      ScrollDirection.idle => _shown || atEnd,
    };
    if (shown != _shown) setState(() => _shown = shown);
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (context) {
      final theme = Theme.of(context);
      return Positioned(
        left: 16,
        right: 16,
        bottom: MediaQuery.paddingOf(context).bottom + 16,
        child: Center(
          child: AnimatedSlide(
            offset: _shown ? Offset.zero : const Offset(0, 2),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: Material(
              elevation: 6,
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: widget.selection.clear),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(widget.label, style: theme.textTheme.titleSmall),
                    ),
                    ...widget.actions,
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
    child: widget.child,
  );
}

/// A selected row's look: tinted, with an outline in the accent colour.
BoxDecoration? selectedRowDecoration(BuildContext context, {required bool selected}) {
  if (!selected) return null;
  final colors = Theme.of(context).colorScheme;
  return BoxDecoration(
    color: colors.primary.withValues(alpha: 0.16),
    border: Border.all(color: colors.primary, width: 2),
    borderRadius: BorderRadius.circular(12),
  );
}
