import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/features/player/player_shortcuts.dart';
import 'package:jellyfin_client/features/settings/keybindings.dart';
import 'package:jellyfin_client/features/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = SingleActivator.new;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Keybindings', () {
    final defaults = Keybindings.defaults;

    test('defaults give every key to one action only', () {
      final all = [for (final e in defaults.entries) ...e.value];
      for (final k in all) {
        expect(all.where((o) => sameKey(o, k)), hasLength(1), reason: describeKey(k));
      }
      expect(defaults.actionFor(_key(LogicalKeyboardKey.keyI)), PlayerAction.playbackInfo);
      expect(defaults.actionFor(_key(LogicalKeyboardKey.keyL)), PlayerAction.seekForward10);
      expect(defaults.actionFor(_key(LogicalKeyboardKey.space)), PlayerAction.playPause);
    });

    test('binding a used key moves it and reports where from', () {
      final (updated, displaced) =
          defaults.bind(PlayerAction.seekForward10, _key(LogicalKeyboardKey.keyI));
      expect(displaced, PlayerAction.playbackInfo);
      expect(updated.actionFor(_key(LogicalKeyboardKey.keyI)), PlayerAction.seekForward10);
      expect(updated.keysFor(PlayerAction.playbackInfo), isEmpty);
      expect(updated.keysFor(PlayerAction.seekForward10).map(describeKey), ['L', 'I']);
    });

    test('modifiers make a different key', () {
      final ctrlS = _key(LogicalKeyboardKey.keyS, control: true);
      final (updated, displaced) = defaults.bind(PlayerAction.playbackInfo, ctrlS);
      expect(displaced, isNull);
      expect(updated.actionFor(_key(LogicalKeyboardKey.keyS)), PlayerAction.skipSegment);
      expect(updated.actionFor(ctrlS), PlayerAction.playbackInfo);
      expect(describeKey(ctrlS), 'Ctrl+S');
    });

    test('unbind removes one key', () {
      final updated =
          defaults.unbind(PlayerAction.playPause, _key(LogicalKeyboardKey.space));
      expect(updated.keysFor(PlayerAction.playPause).map(describeKey),
          ['Media Play Pause']);
    });

    test('JSON round trip; new actions keep defaults', () {
      final (custom, _) = defaults.bind(
        PlayerAction.toggleFullscreen,
        _key(LogicalKeyboardKey.enter, alt: true),
      );
      final json = custom.toJson()..remove(PlayerAction.playbackInfo.name);
      final restored = Keybindings.fromJson(json);
      expect(restored.keysFor(PlayerAction.toggleFullscreen).map(describeKey),
          ['F', 'Alt+Enter']);
      expect(restored.actionFor(_key(LogicalKeyboardKey.keyI)), PlayerAction.playbackInfo);
    });

    test('player shortcuts map every bound key to its action', () {
      final ran = <PlayerAction>[];
      final shortcuts = playerShortcuts(defaults, {
        for (final a in PlayerAction.values) a: () => ran.add(a),
      });
      for (final MapEntry(key: activator, value: run) in shortcuts.entries) {
        run();
        expect(ran.last, defaults.actionFor(activator as SingleActivator));
      }
      expect(ran.toSet(), PlayerAction.values.toSet());
    });
  });

  group('Settings > Player controls', () {
    Future<ProviderContainer> pump(WidgetTester tester, {bool tv = false}) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: [isTvProvider.overrideWithValue(tv)]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ));
      await tester.pumpAndSettle();
      if (!tv) {
        await tester.tap(find.text('Player controls'));
        await tester.pumpAndSettle();
      }
      return container;
    }

    testWidgets('pressing a key rebinds it and saves', (tester) async {
      final container = await pump(tester);
      expect(find.text('Keyboard shortcuts'), findsOneWidget);

      await tester.tap(find.text('Forward 10 seconds'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();

      expect(find.textContaining('was used for "Playback info"'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'I'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final bindings = container.read(keybindingsProvider).value!;
      expect(bindings.actionFor(_key(LogicalKeyboardKey.keyI)), PlayerAction.seekForward10);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('player.keybindings'), contains('seekForward10'));

      // Escape is bindable too: the dialog doesn't close on it.
      await tester.tap(find.text('Playback info'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        container.read(keybindingsProvider).value!.actionFor(_key(LogicalKeyboardKey.escape)),
        PlayerAction.playbackInfo,
      );
    });

    testWidgets('keyboard and mouse settings are hidden on a TV', (tester) async {
      await pump(tester, tv: true);
      expect(find.text('Player controls'), findsNothing, reason: 'no keyboard or touch on a TV');
      expect(find.text('Keyboard shortcuts'), findsNothing);
      expect(find.text('Click video to play / pause'), findsNothing);
      await tester.tap(find.text('Account & server'));
      await tester.pumpAndSettle();
      expect(find.text('Trusted certificates'), findsOneWidget, reason: 'still relevant');
    });

    testWidgets('removing a key and resetting to defaults', (tester) async {
      final container = await pump(tester);
      await tester.tap(find.text('Skip intro / recap / credits'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('No keys yet.'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(container.read(keybindingsProvider).value!
          .keysFor(PlayerAction.skipSegment), isEmpty);

      await tester.tap(find.text('Reset controls to defaults'));
      await tester.pumpAndSettle();
      expect(container.read(keybindingsProvider).value!
          .actionFor(_key(LogicalKeyboardKey.keyS)), PlayerAction.skipSegment);
    });
  });
}
