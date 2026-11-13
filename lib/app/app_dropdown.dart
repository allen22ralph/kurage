import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'layout.dart';

/// The app's dropdown: rounded (its focus highlight and its menu, as the
/// rest of the app), and after a choice it lets go of the focus, so no
/// highlight box is left behind once the mouse has picked. On a TV the
/// focus stays: the remote moves on from there.
class AppDropdown<T> extends ConsumerStatefulWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.underline,
    this.isExpanded = false,
  });

  final T? value;
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;
  final Widget? underline;
  final bool isExpanded;

  static const radius = BorderRadius.all(Radius.circular(12));

  @override
  ConsumerState<AppDropdown<T>> createState() => _AppDropdownState<T>();
}

class _AppDropdownState<T> extends ConsumerState<AppDropdown<T>> {
  final _focus = FocusNode(debugLabel: 'AppDropdown');

  /// The menu was opened: it hands the focus back as it closes, and it's
  /// let go again then.
  bool _release = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_release && _focus.hasFocus) {
        _release = false;
        _focus.unfocus();
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tv = ref.watch(isTvProvider);
    final changed = widget.onChanged;
    return DropdownButton<T>(
      focusNode: _focus,
      value: widget.value,
      items: widget.items,
      hint: widget.hint,
      isExpanded: widget.isExpanded,
      underline: widget.underline ?? const SizedBox.shrink(),
      borderRadius: AppDropdown.radius,
      // Opened: however it closes (a choice, a click outside, Esc), the
      // focus it gets back is let go.
      onTap: tv ? null : () => _release = true,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      onChanged: changed == null
          ? null
          : (v) {
              changed(v);
              if (!tv) {
                _release = true;
                if (_focus.hasFocus) _focus.unfocus();
              }
            },
    );
  }
}
