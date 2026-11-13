import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:jellyfin_client/features/home/depth/preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_server.dart';

void main() {
  testWidgets('the stage says Preview only while one plays, not over a still', (tester) async {
    // Balanced: no preview starts, so what's under the mouse stays a still.
    SharedPreferences.setMockInitialValues({'theme.id': 'depth', 'appearance.effects': 'balanced'});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
    final server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([itemJson('ep1', 'An episode', type: 'Episode')])),
      '/Shows/NextUp': (200, pageJson([])),
      '/Items/Latest': (200, []),
      '/Genres': (200, pageJson([])),
      '/Items': (200, pageJson([])),
    });
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    addTearDown(() => Preview.showing.value = null);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    final stage = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Stage');
    expect(stage, findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(stage));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('PREVIEW'), findsNothing, reason: 'hovering, but a still');

    Preview.showing.value = 'ep1';
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('PREVIEW'), findsOneWidget);

    Preview.showing.value = null;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('PREVIEW'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
