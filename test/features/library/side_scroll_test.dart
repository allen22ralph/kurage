import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/library/widgets/side_scroll.dart';

void main() {
  testWidgets('hovering a long row shows › (then ‹); they page sideways', (tester) async {
    late ScrollController list;
    await tester.pumpWidget(MaterialApp(
      scrollBehavior: const AppScrollBehavior(),
      home: Scaffold(
        body: SizedBox(
          height: 120,
          child: SideScroll(builder: (controller) {
            list = controller;
            return ListView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              children: [for (var i = 0; i < 30; i++) SizedBox(width: 150, child: Text('Card $i'))],
            );
          }),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsNothing, reason: 'only while hovered');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byType(SideScroll)));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing, reason: 'nothing to the left yet');

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(list.offset, greaterThan(500));
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);

    // A mouse can drag the row too.
    final before = list.offset;
    await tester.dragFrom(tester.getCenter(find.byType(SideScroll)), const Offset(300, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(list.offset, lessThan(before));
  });
}
