import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/player/player_look.dart';
import 'package:jellyfin_client/features/player/widgets/player_controls.dart';
import 'package:jellyfin_client/features/player/widgets/player_look_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the time beside the seek bar: elapsed / total, time left, or when it ends', () {
    const at = Duration(minutes: 5, seconds: 9);
    const of = Duration(minutes: 26, seconds: 1);
    final now = DateTime(2026, 10, 30, 0, 54);
    expect(PlayerTimeLabel.text(TimeDisplay.elapsed, at, of), '5:09 / 26:01');
    expect(PlayerTimeLabel.text(TimeDisplay.remaining, at, of), '−20:52');
    expect(PlayerTimeLabel.text(TimeDisplay.endsAt, at, of, now: now), 'Ends at 01:14');
    expect(PlayerTimeLabel.text(TimeDisplay.endsAt, at, of, now: now, rate: 2), 'Ends at 01:04', reason: 'faster: sooner');
    expect(PlayerTimeLabel.text(TimeDisplay.elapsed, const Duration(hours: 1, minutes: 2, seconds: 3), of), '1:02:03 / 26:01');
  });

  test('the player look is kept; Large is the size on a PC unless chosen', () async {
    var c = ProviderContainer();
    final look = await c.read(playerLookProvider.future);
    // Large on a PC (Windows); CI runs the tests on Linux.
    expect(look.size, Platform.isWindows ? ControlsSize.large : ControlsSize.normal);
    expect(look.buttons, PlayerLook.defaultButtons);
    await c.read(playerLookProvider.notifier).save(look.copyWith(
          theme: PlayerTheme.glass,
          size: ControlsSize.normal,
          buttons: {PlayerButton.speed, PlayerButton.chapters},
          time: TimeDisplay.endsAt,
          chapterMarks: false,
          trickplay: false,
          hideAfterSeconds: 7,
          titleArea: TitleArea.title,
        ));
    c.dispose();
    c = ProviderContainer();
    addTearDown(c.dispose);
    final back = await c.read(playerLookProvider.future);
    expect(
      (back.theme, back.size, back.time, back.chapterMarks, back.trickplay, back.hideAfterSeconds, back.titleArea),
      (PlayerTheme.glass, ControlsSize.normal, TimeDisplay.endsAt, false, false, 7, TitleArea.title),
    );
    expect(back.buttons, {PlayerButton.speed, PlayerButton.chapters});
    expect(back.iconSize, lessThan(const PlayerLook(size: ControlsSize.large).iconSize));
  });

  testWidgets('Player layout settings, and a preview in every theme', (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: PlayerLookSection()))),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerLookPreview), findsOneWidget);
    expect(find.descendant(of: find.byType(PlayerLookPreview), matching: find.text('5:09 / 26:01')), findsOneWidget,
        reason: 'the preview shows the chosen time');
    for (final theme in PlayerTheme.values) {
      await c.read(playerLookProvider.notifier).save((await c.read(playerLookProvider.future)).copyWith(theme: theme));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '${theme.label} draws');
    }
    Finder inPreview(IconData icon) => find.descendant(of: find.byType(PlayerLookPreview), matching: find.byIcon(icon));
    await c.read(playerLookProvider.notifier).save((await c.read(playerLookProvider.future)).copyWith(theme: PlayerTheme.standard));
    await tester.pumpAndSettle();
    expect(inPreview(Icons.speed), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'Speed'));
    await tester.pumpAndSettle();
    expect((await c.read(playerLookProvider.future)).shows(PlayerButton.speed), isTrue);
    expect(inPreview(Icons.speed), findsOneWidget, reason: 'every button shows in the preview');
    await tester.tap(find.widgetWithText(FilterChip, 'Back / ahead 10 s'));
    await tester.pumpAndSettle();
    expect(inPreview(Icons.replay_10), findsOneWidget);
    expect(tester.getSize(find.descendant(of: find.byType(PlayerLookPreview), matching: find.byType(AspectRatio))).width, lessThanOrEqualTo(640 + 0.1),
        reason: "the preview doesn't fill a wide pane");
  });
}
