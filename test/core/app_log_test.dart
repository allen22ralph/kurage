import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/notifications.dart';
import 'package:jellyfin_client/app/toast.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';
import 'package:jellyfin_client/core/log/app_log.dart';
import 'package:jellyfin_client/features/settings/app_log_screen.dart';

import '../support/fake_server.dart';

void main() {
  setUp(() async {
    await AppLog.reset();
    NotificationHistory.reset();
  });

  test('a line reads back from its text form (kept across restarts)', () {
    final e = LogEntry(DateTime(2026, 10, 29, 3, 4, 5, 6), LogLevel.warning, LogArea.seerr, "Seerr isn't reachable");
    final line = e.format(withDate: true);
    expect(line, "2026-10-29 03:04:05.006 W [seerr] Seerr isn't reachable");
    final back = LogEntry.parse(line)!;
    expect((back.at, back.level, back.area, back.message), (e.at, e.level, e.area, e.message));
    expect(LogEntry.parse('    a stack trace line'), isNull);
  });

  test('details (errors, stacks) are indented under their line; the log keeps its last lines', () {
    AppLog.error(LogArea.app, 'Something broke', error: StateError('bad'));
    expect(AppLog.text(), contains('E [app] Something broke\n    Bad state: bad'));
    // A message over several lines keeps one line in the file; the rest goes under it.
    AppLog.info(LogArea.player, 'Track choices: FormatException\nstable\n^');
    expect(AppLog.entries.value.last.message, 'Track choices: FormatException');
    expect(AppLog.text(), contains('[player] Track choices: FormatException\n    stable\n    ^'));
    for (var i = 0; i < AppLog.capacity + 5; i++) {
      AppLog.debug(LogArea.app, 'line $i');
    }
    expect(AppLog.entries.value, hasLength(AppLog.capacity));
    expect(AppLog.entries.value.last.message, 'line ${AppLog.capacity + 4}');
  });

  test('requests are logged by path only: no server address, no tokens; failures with the reason', () async {
    final server = FakeServer({
      '/Users/Me': (200, {'Id': 'u1', 'Name': 'sam'}),
      '/Items/x': (500, {'Message': 'Database is locked'}),
    });
    final api = JellyfinApi(
      baseUrl: Uri.parse('https://jellyfin.home.arpa'),
      clientInfo: testClientInfo,
      accessToken: 'secret-token',
      dio: Dio()..httpClientAdapter = server,
    );
    await api.getCurrentUser();
    await expectLater(api.getJson('/Items/x', query: {'api_key': 'secret-token'}), throwsA(isA<JellyfinException>()));
    final text = AppLog.text();
    expect(text, contains('D [network] GET /Users/Me → 200'));
    expect(text, contains('W [network] GET /Items/x → 500'));
    expect(text, contains('Database is locked'));
    expect(text, isNot(contains('secret-token')));
    expect(text, isNot(contains('jellyfin.home.arpa')));
  });

  test('every toast is kept in the history; the same id replaces; unread counts', () {
    var retried = 0;
    showToast('Downloading 1 of 3', id: 'dl');
    showToast('Downloading 2 of 3', id: 'dl');
    showToast("Couldn't download Frieren", actionLabel: 'Retry', onAction: () => retried++);
    final items = NotificationHistory.items.value;
    expect([for (final n in items) n.message], ["Couldn't download Frieren", 'Downloading 2 of 3']);
    expect(NotificationHistory.unread.value, 2);
    items.first.onAction!();
    expect(retried, 1);
    expect(AppLog.text(), contains('[notification] Downloading 2 of 3'));
  });

  testWidgets('the bell shows unread messages; its panel runs their actions', (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(appBar: AppBar(actions: const [NotificationBell()])),
    ));
    NotificationHistory.add('Frieren is now available', actionLabel: 'Open', onAction: () => opened++);
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();
    expect(find.text('Frieren is now available'), findsOneWidget);
    expect(NotificationHistory.unread.value, 0);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('Notifications'), findsNothing, reason: 'the panel closed');
  });

  testWidgets('the log screen filters by area and level, and copies what it shows', (tester) async {
    AppLog.debug(LogArea.network, 'GET /Users/Me → 200 (12 ms)');
    AppLog.warning(LogArea.seerr, "Seerr isn't reachable");
    AppLog.info(LogArea.player, 'Open abc at 0:00:00');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(const MaterialApp(home: AppLogScreen()));
    expect(find.textContaining('GET /Users/Me'), findsNothing, reason: 'debug lines are hidden at first');
    expect(find.textContaining("Seerr isn't reachable"), findsOneWidget);
    expect(find.textContaining('Open abc'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Seerr'));
    await tester.pump();
    expect(find.textContaining('Open abc'), findsNothing);
    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    expect(copied, contains("W [seerr] Seerr isn't reachable"));
    expect(copied, isNot(contains('Open abc')));
  });
}
