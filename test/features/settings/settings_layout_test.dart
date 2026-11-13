import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/features/settings/keybindings.dart';
import 'package:jellyfin_client/features/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Size size, {SettingsCategory? initial}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [isTvProvider.overrideWithValue(false)],
      child: MaterialApp(home: SettingsScreen(initial: initial)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('wide: categories on the left, the chosen one on the right', (tester) async {
    await pump(tester, const Size(1200, 900));
    expect(find.text('Playback'), findsWidgets);
    expect(find.text('Preferred audio languages'), findsOneWidget, reason: 'Playback opens first');
    await tester.tap(find.widgetWithText(ListTile, 'MyAnimeList'));
    await tester.pumpAndSettle();
    expect(find.text('Show MyAnimeList scores'), findsOneWidget);
    expect(find.text('Preferred audio languages'), findsNothing);
  });

  testWidgets('phone: a list of categories, each opening its page; back returns to the list', (tester) async {
    await pump(tester, const Size(400, 900));
    expect(find.text('Preferred audio languages'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, 'Troubleshooting'));
    await tester.pumpAndSettle();
    expect(find.text('Playback log'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Search settings'), findsOneWidget);
  });

  testWidgets('search finds a setting by name and opens its category', (tester) async {
    await pump(tester, const Size(1200, 900));
    await tester.tap(find.widgetWithText(ListTile, 'Home'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'scores');
    await tester.pumpAndSettle();
    expect(find.text('Show MyAnimeList scores'), findsOneWidget, reason: 'one result (Home is open on the right)');
    await tester.tap(find.text('Show MyAnimeList scores'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SwitchListTile, 'Show MyAnimeList scores'), findsOneWidget);
    expect(find.text('Search settings'), findsOneWidget, reason: 'search cleared');
  });

  testWidgets('opens on the category asked for (?section=)', (tester) async {
    await pump(tester, const Size(400, 900), initial: SettingsCategory.troubleshooting);
    expect(find.text('Playback log'), findsOneWidget);
    expect(SettingsCategory.fromName('troubleshooting'), SettingsCategory.troubleshooting);
    expect(SettingsCategory.fromName('nope'), isNull);
  });

  test('each device lists only what applies on it', () {
    const tv = SettingsDevice(isTv: true, isAndroid: true);
    const phone = SettingsDevice(isTv: false, isAndroid: true);
    const desktop = SettingsDevice(isTv: false, isAndroid: false);
    expect(tv.categories, isNot(contains(SettingsCategory.controls)));
    expect(phone.settingsIn(SettingsCategory.controls), contains('Double-tap to skip'));
    expect(phone.settingsIn(SettingsCategory.controls), isNot(contains('Keyboard shortcuts')));
    expect(desktop.settingsIn(SettingsCategory.controls), contains(PlayerAction.values.first.label));
    expect(desktop.search('hardware').single.category, SettingsCategory.playback);
    expect(phone.search('hardware'), isEmpty);
  });
}
