import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app_dropdown.dart';
import 'package:jellyfin_client/app/layout.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool tv, required ValueNotifier<String> value}) =>
      tester.pumpWidget(ProviderScope(
        overrides: [isTvProvider.overrideWithValue(tv)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ValueListenableBuilder<String>(
                valueListenable: value,
                builder: (_, v, _) => AppDropdown<String>(
                  value: v,
                  items: const [
                    DropdownMenuItem(value: 'Dark', child: Text('Dark')),
                    DropdownMenuItem(value: 'Glass', child: Text('Glass')),
                  ],
                  onChanged: (n) => value.value = n ?? v,
                ),
              ),
            ),
          ),
        ),
      ));

  for (final tv in [false, true]) {
    testWidgets(tv ? 'TV: the focus stays after a choice (the remote goes on from there)' : 'after a choice the focus goes: no box left behind', (tester) async {
      final value = ValueNotifier('Dark');
      await pump(tester, tv: tv, value: value);
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Glass').last);
      await tester.pumpAndSettle();
      expect(value.value, 'Glass');
      final dropdown = tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
      expect(dropdown.borderRadius, AppDropdown.radius);
      final focused = FocusManager.instance.primaryFocus;
      final inDropdown = focused?.context != null &&
          find.descendant(of: find.byType(DropdownButton<String>), matching: find.byWidgetPredicate((w) => w is Focus)).evaluate().any((e) => e == focused!.context);
      expect(inDropdown, tv);
    });
  }
}
