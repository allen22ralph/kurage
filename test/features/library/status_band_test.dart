import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/library/item_detail_screen.dart';

void main() {
  testWidgets('the band shows once scrolled, and goes with the status bar on the way down', (tester) async {
    final scrolled = ValueNotifier<double>(0);
    final goingDown = ValueNotifier<bool>(false);
    addTearDown(scrolled.dispose);
    addTearDown(goingDown.dispose);
    await tester.pumpWidget(StatusBand(scrolled: scrolled, goingDown: goingDown));

    double scrolledIn() => tester.widget<Opacity>(find.byType(Opacity).last).opacity;
    double shown() => tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

    expect(scrolledIn(), 0, reason: 'at the top of the page');
    expect(shown(), 1);

    scrolled.value = 300;
    await tester.pump();
    expect(scrolledIn(), 1);

    goingDown.value = true;
    await tester.pump();
    expect(shown(), 0, reason: 'the status bar has gone');

    goingDown.value = false;
    await tester.pump();
    expect(shown(), 1, reason: 'it has come back');
    await tester.pumpAndSettle();
  });
}
