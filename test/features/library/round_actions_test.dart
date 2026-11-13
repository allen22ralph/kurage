import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/library/depth/detail_parts.dart';

void main() {
  Future<void> pump(WidgetTester tester, int count) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: RoundActions(
              children: [for (var i = 0; i < count; i++) RoundAction(label: 'A$i', icon: Icons.check, onPressed: () {})],
            ),
          ),
        ),
      ));

  testWidgets('five fit in one row', (tester) async {
    await pump(tester, 5);
    final ys = {for (var i = 0; i < 5; i++) tester.getTopLeft(find.text('A$i')).dy};
    expect(ys, hasLength(1));
  });

  testWidgets('a sixth goes on a second row, centred', (tester) async {
    await pump(tester, 6);
    final first = tester.getCenter(find.text('A0'));
    final sixth = tester.getCenter(find.text('A5'));
    expect(sixth.dy, greaterThan(first.dy));
    expect(sixth.dx, closeTo(390 / 2, 1));
    expect(tester.getCenter(find.text('A4')).dy, first.dy);
  });
}
