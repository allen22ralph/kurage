import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/layout.dart';
import 'package:jellyfin_client/app/system_nav_bar.dart';

void main() {
  late List<String> modes;

  setUp(() {
    SystemNavBar.debugAndroid = true;
    modes = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') modes.add('${call.arguments}');
        if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') modes.add('overlays ${call.arguments}');
        return null;
      },
    );
  });

  tearDown(() {
    SystemNavBar.debugAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pump(WidgetTester tester, {bool tv = false}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [isTvProvider.overrideWithValue(tv)],
      child: MaterialApp(
        navigatorObservers: [SystemNavBar.observer()],
        builder: (context, child) => SystemNavBar(child: child!),
        home: Scaffold(
          body: ListView(children: [for (var i = 0; i < 60; i++) ListTile(title: Text('Row $i'))]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  // Manual mode reaches Android as the bars to keep: the status bar only.
  bool hidden() => modes.isNotEmpty && modes.last == 'overlays [SystemUiOverlay.top]';

  testWidgets('Android phone: scrolling down hides the bar, scrolling up brings it back', (tester) async {
    await pump(tester);
    expect(hidden(), isFalse);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(hidden(), isTrue);

    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(hidden(), isFalse);
    expect(modes.last, contains('edgeToEdge'));
  });

  testWidgets('on a page that asks for it, the status bar goes too, and comes back', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        navigatorObservers: [SystemNavBar.observer()],
        builder: (context, child) => SystemNavBar(child: child!),
        home: Scaffold(
          body: HidesStatusBar(
            child: ListView(children: [for (var i = 0; i < 60; i++) ListTile(title: Text('Row $i'))]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(modes.last, 'overlays []');

    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(modes.last, contains('edgeToEdge'));
  });

  testWidgets('another page brings it back', (tester) async {
    await pump(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(hidden(), isTrue);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Details'))));
    await tester.pumpAndSettle();
    expect(hidden(), isFalse);
  });

  testWidgets('a page that scrolls: Android\'s own strip; one that can\'t: the page shows through', (tester) async {
    await pump(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -50));
    await tester.pumpAndSettle();
    final scrolling = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byWidgetPredicate((w) => w is AnnotatedRegion<SystemUiOverlayStyle> && w.value.systemNavigationBarContrastEnforced != null),
    );
    expect(scrolling.value.systemNavigationBarContrastEnforced, isTrue);

    tester.state<NavigatorState>(find.byType(Navigator)).push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Center(child: Text('Sign in')))),
    );
    await tester.pumpAndSettle();
    final still = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byWidgetPredicate((w) => w is AnnotatedRegion<SystemUiOverlayStyle> && w.value.systemNavigationBarContrastEnforced != null),
    );
    expect(still.value.systemNavigationBarContrastEnforced, isFalse);
    expect(still.value.systemNavigationBarColor, Colors.transparent);
  });

  testWidgets('TVs leave it alone', (tester) async {
    await pump(tester, tv: true);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(modes, isEmpty, reason: 'TV');
  });
}
