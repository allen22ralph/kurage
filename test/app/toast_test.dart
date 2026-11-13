import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/toast.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(builder: (_, child) => ToastHost(child: child!), home: const Scaffold()));
  }

  testWidgets('desktop: top right; goes by itself even with an action; ✕ closes it', (tester) async {
    await pumpHost(tester);
    var opened = false;
    showToast('Downloading Frieren', actionLabel: 'Open', onAction: () => opened = true);
    await tester.pumpAndSettle();
    final at = tester.getTopRight(find.text('Downloading Frieren'));
    expect(at.dy, lessThan(100), reason: 'at the top');
    expect(at.dx, greaterThan(1100), reason: 'on the right');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Downloading Frieren'), findsNothing, reason: 'gone after 4 s, without pressing Open');
    expect(opened, isFalse);

    showToast('Requested New Anime.');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Requested New Anime.'), findsNothing);
  });

  testWidgets('hovering keeps it; the same id replaces rather than piles up', (tester) async {
    await pumpHost(tester);
    showToast('Downloading 1', id: 'downloading');
    showToast('Downloading 2', id: 'downloading');
    await tester.pumpAndSettle();
    expect(find.text('Downloading 1'), findsNothing);
    expect(find.text('Downloading 2'), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Downloading 2')));
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Downloading 2'), findsOneWidget, reason: 'kept while hovered');
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Downloading 2'), findsNothing);
  });
}
