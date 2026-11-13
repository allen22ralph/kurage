import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/theme.dart';
import 'package:jellyfin_client/features/settings/appearance.dart';
import 'package:jellyfin_client/theme/theme_choice.dart';
import 'package:jellyfin_client/theme/theme_files.dart';
import 'package:jellyfin_client/theme/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// As the app is themed, around Settings > Appearance's theme parts.
class _App extends ConsumerWidget {
  const _App();

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
        theme: buildTheme(
          ref.watch(appearanceProvider).value ?? const AppearanceSettings(),
          ref.watch(activeThemeProvider),
          ref.watch(themeChoiceProvider.select((c) => c.value?.font)),
          const <String>{},
          false,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: Column(children: [ThemeSection(), ThemeFilesSection(), AppearanceSection()]),
          ),
        ),
      );
}

void main() {
  testWidgets('removing the imported Depth in use goes back to Classic without hanging', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.read(themeChoiceProvider.future);
      await c.read(importedThemesProvider.future);
      await c.read(appearanceProvider.future);
      // Depth exported, then brought back in: a copy, in use.
      await c.read(themeChoiceProvider.notifier).save(ThemeChoice(themeId: 'depth'));
      final file = parseThemeFile(await exportThemeFile(c));
      await useImportedTheme(c, file, withSettings: true);
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const _App()));
    await tester.pump(const Duration(seconds: 1));
    expect(c.read(activeThemeProvider).id, 'depth-2');

    final remove = find.textContaining('Remove Depth').first;
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(c.read(activeThemeProvider).id, 'classic');
    expect(find.textContaining('Remove Depth'), findsNothing);
    // The messages' timers run out.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
