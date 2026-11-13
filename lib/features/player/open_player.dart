import 'package:flutter/foundation.dart';

/// The player open now, as the player itself says (the router can't tell:
/// a player pushed over another screen isn't its "current" location).
class OpenPlayer {
  OpenPlayer._();

  /// The item the newest open player shows; null with none open.
  static final itemId = ValueNotifier<String?>(null);

  static String? _leftItem;
  static DateTime? _leftAt;

  /// The user left the player showing [id].
  static void left(String id) {
    _leftItem = id.replaceAll('-', '').toLowerCase();
    _leftAt = DateTime.now();
  }

  /// Just left [id] (moments ago): nothing but the user should open it
  /// again (a group update arriving as it closed did, at an old position).
  static bool justLeft(String id, {Duration within = const Duration(seconds: 3)}) =>
      _leftItem == id.replaceAll('-', '').toLowerCase() && _leftAt != null && DateTime.now().difference(_leftAt!) < within;
}
