import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_server.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(signedInStorage());
  });

  Future<FakeServer> pumpAccounts(WidgetTester tester, {required int status}) async {
    final server = FakeServer({
      '/UserViews': (200, pageJson([])),
      '/UserItems/Resume': (200, pageJson([])),
      '/Shows/NextUp': (200, pageJson([])),
      'POST /QuickConnect/Authorize': (status, status == 200 ? true : null),
    });
    final c = ProviderContainer(overrides: fakeServerOverrides(server));
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const JellyfinClientApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(RegExp('Accounts')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve a Quick Connect code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Code'), '123456');
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();
    return server;
  }

  testWidgets('approving a code signs the other device in', (tester) async {
    final server = await pumpAccounts(tester, status: 200);
    expect(server.requestsTo('/QuickConnect/Authorize').single.queryParameters['code'], '123456');
    expect(find.textContaining('Approved'), findsOneWidget);
    expect(find.text('Approve a Quick Connect code'), findsOneWidget, reason: 'dialog closed, tile remains');
  });

  testWidgets('an unknown code says so and keeps the dialog open', (tester) async {
    await pumpAccounts(tester, status: 404);
    expect(find.textContaining('No device is waiting with that code'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Code'), findsOneWidget);
  });
}
