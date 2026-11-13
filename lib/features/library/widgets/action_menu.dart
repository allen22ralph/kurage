import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// One choice in a card's menu.
class MenuEntry {
  const MenuEntry({required this.icon, required this.label, required this.onSelected, this.subtitle});

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onSelected;
}

/// Holding opens a card's menu on a phone or TV, where nothing else can;
/// on a PC right-click does, and a hold does nothing.
bool get holdOpensMenu => debugHoldOpensMenu ?? (Platform.isAndroid || Platform.isIOS);

/// Tests on a PC that act as a phone or TV.
@visibleForTesting
bool? debugHoldOpensMenu;

/// Where the mouse was last pressed, and when: a menu opened by holding the
/// mouse (no position given) opens there, as a right-click's does.
Offset? _mouseAt;
DateTime _mouseWhen = DateTime(0);
bool _tracking = false;

/// Starts noting mouse presses, app-wide. Called once at start-up (and,
/// to be safe, by the first menu).
void trackMousePresses() {
  if (_tracking) return;
  _tracking = true;
  GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
    if (event is! PointerDownEvent) return;
    // A touch (a phone, a touchscreen) holds for the sheet instead.
    _mouseAt = event.kind == PointerDeviceKind.mouse ? event.position : null;
    _mouseWhen = DateTime.now();
  });
}

/// The mouse press that just led here (a hold), if there was one.
Offset? _recentMousePress() {
  final at = _mouseAt;
  if (at == null || DateTime.now().difference(_mouseWhen) > const Duration(seconds: 3)) return null;
  return at;
}

/// A card's menu: a popup at [at] (right-click, where the mouse is), or a
/// bottom sheet (long press by touch, ⋮, a remote's menu key). Held with a
/// mouse, it's the popup too, where the mouse is.
///
/// The menu closes before an entry runs, so entries can open pages or
/// dialogs of their own.
Future<void> showActionMenu(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<MenuEntry> entries,
  Offset? at,
}) async {
  trackMousePresses();
  at ??= _recentMousePress();
  if (at != null) {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final chosen = await showMenu<MenuEntry>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        for (final e in entries)
          PopupMenuItem(
            value: e,
            child: Row(
              children: [
                Icon(e.icon, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(e.label)),
              ],
            ),
          ),
      ],
    );
    chosen?.onSelected();
    return;
  }
  final chosen = await showModalBottomSheet<MenuEntry>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(title, style: Theme.of(sheet).textTheme.titleMedium),
              subtitle: subtitle == null ? null : Text(subtitle),
            ),
            for (final (i, e) in entries.indexed)
              ListTile(
                autofocus: i == 0,
                leading: Icon(e.icon),
                title: Text(e.label),
                subtitle: e.subtitle == null ? null : Text(e.subtitle!),
                onTap: () => Navigator.pop(sheet, e),
              ),
          ],
        ),
      ),
    ),
  );
  chosen?.onSelected();
}
