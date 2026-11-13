import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/library/widgets/action_menu.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    trackMousePresses();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => GestureDetector(
              onLongPress: () => showActionMenu(
                context,
                title: 'A show',
                entries: [MenuEntry(icon: Icons.info_outline, label: 'Details', onSelected: () {})],
              ),
              child: const SizedBox(width: 200, height: 200, child: Text('Card')),
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('held with the mouse: the dropdown, where the mouse is', (tester) async {
    await pump(tester);
    final at = tester.getCenter(find.text('Card'));
    await tester.longPressAt(at, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<MenuEntry>), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    final menu = tester.getTopLeft(find.byType(PopupMenuItem<MenuEntry>));
    expect((menu - at).distance, lessThan(250), reason: 'next to the pointer');
  });

  testWidgets('held by touch: the sheet, as on a phone', (tester) async {
    await pump(tester);
    await tester.longPress(find.text('Card'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  test('on a PC a hold opens nothing (right-click does); on a phone or TV it does', () {
    debugHoldOpensMenu = null;
    expect(holdOpensMenu, isFalse, reason: 'these tests run on a PC');
    debugHoldOpensMenu = true;
    expect(holdOpensMenu, isTrue);
    debugHoldOpensMenu = null;
  });
}