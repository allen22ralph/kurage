import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/smooth_wheel.dart';

void main() {
  late ScrollController controller;

  Future<TestPointer> list(WidgetTester tester, {bool animations = true}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: const Size(800, 600), disableAnimations: !animations),
            child: SmoothWheel(
              builder: (context, c) {
                controller = c;
                return ListView.builder(
                  controller: c,
                  itemCount: 100,
                  itemBuilder: (_, i) => SizedBox(height: 100, child: Text('row $i')),
                );
              },
            ),
          ),
        ),
      ),
    );
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    mouse.hover(const Offset(400, 300));
    return mouse;
  }

  double at() => controller.position.pixels;

  testWidgets('a notch glides there, instead of jumping', (tester) async {
    final mouse = await list(tester);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(at(), greaterThan(0));
    expect(at(), lessThan(100), reason: 'on its way');
    await tester.pumpAndSettle();
    expect(at(), 100);
  });

  testWidgets('quick notches add up, and it stops at the ends', (tester) async {
    final mouse = await list(tester);
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    expect(at(), 300);

    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -1000)));
    await tester.pumpAndSettle();
    expect(at(), 0);

    // Past the top already: nothing to do, and a later notch still works.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
    await tester.pumpAndSettle();
    expect(at(), 0);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.pumpAndSettle();
    expect(at(), 100);
  });

  testWidgets('a drag takes over from a glide', (tester) async {
    final mouse = await list(tester);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 500)));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.drag(find.byType(ListView), const Offset(0, -50));
    await tester.pumpAndSettle();
    final after = at();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.pumpAndSettle();
    expect(at(), after + 100, reason: 'from where it is now, not the old target');
  });

  testWidgets('with animations off, the wheel steps', (tester) async {
    final mouse = await list(tester, animations: false);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.pump();
    expect(at(), 100);
  });
}
