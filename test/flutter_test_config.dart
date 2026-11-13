import 'dart:async';

import 'package:jellyfin_client/theme/theme_choice.dart';

/// Runs before every test file: tests were written against Classic as the
/// theme a fresh install shows, so that stays their starting point (a test
/// of the real default clears this).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugDefaultThemeId = 'classic';
  await testMain();
}
