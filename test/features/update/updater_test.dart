import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/app/notifications.dart';
import 'package:jellyfin_client/core/update/app_update.dart';
import 'package:jellyfin_client/features/update/update_ui.dart';
import 'package:jellyfin_client/features/update/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/update/app_update_test.dart' show releaseJson;
import '../../support/fake_server.dart';

class _FakeInstaller extends UpdateInstaller {
  final installed = <String>[];

  /// What each install returns, in turn (then the last one again).
  List<InstallResult> results = [InstallResult.notWritable];
  bool allowed = false;

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<InstallResult> install(AppRelease release, {void Function(double progress)? onProgress}) async {
    onProgress?.call(0.5);
    installed.add(release.tag);
    return results[(installed.length - 1).clamp(0, results.length - 1)];
  }
}

void main() {
  late FakeServer server;
  late _FakeInstaller installer;

  setUp(() {
    NotificationHistory.reset();
    installer = _FakeInstaller();
    server = FakeServer({
      'https://api.github.com/repos/$releasesRepo/releases': (200, [
        releaseJson('v0.3.3-beta.1', prerelease: true),
        releaseJson('v0.3.2'),
      ]),
    });
  });

  ProviderContainer container(String version, [Map<String, Object> prefs = const {}]) {
    SharedPreferences.setMockInitialValues(prefs);
    final c = ProviderContainer(overrides: [
      ...fakeServerOverrides(server),
      currentVersionProvider.overrideWithValue(AppVersion.tryParse(version)!),
      updateInstallerProvider.overrideWithValue(installer),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('the channel starts as the installed version\'s, and is kept', () async {
    expect((await container('0.3.2-beta.3').read(updateSettingsProvider.future)).channel, UpdateChannel.beta);
    expect((await container('0.3.1').read(updateSettingsProvider.future)).channel, UpdateChannel.stable);
    final c = container('0.3.1', {'update.channel': 'beta'});
    expect((await c.read(updateSettingsProvider.future)).channel, UpdateChannel.beta);
  });

  test('a check finds the newest on the channel; changing channel checks again', () async {
    final c = container('0.3.1');
    expect((await c.read(updateCheckProvider.notifier).check())?.tag, 'v0.3.2');
    final settings = await c.read(updateSettingsProvider.future);
    await c.read(updateSettingsProvider.notifier).save(settings.copyWith(channel: UpdateChannel.beta));
    await pumpEventQueue();
    expect(c.read(updateCheckProvider).available?.tag, 'v0.3.3-beta.1');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('update.channel'), 'beta');
  });

  test("a failed check says why and doesn't throw", () async {
    server.routes.clear();
    final c = container('0.3.1');
    expect(await c.read(updateCheckProvider.notifier).check(), isNull);
    expect(c.read(updateCheckProvider).error, 'No releases found');
  });

  Future<ProviderContainer> pumpSection(WidgetTester tester, String version) async {
    final c = container(version);
    await c.read(updateSettingsProvider.future);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: UpdatesSection()))),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('Settings: Check now, then Update shows what\'s new and installs', (tester) async {
    await pumpSection(tester, '0.3.1');
    expect(find.text('You have 0.3.1'), findsOneWidget);
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    expect(find.text('Version 0.3.2 is available (you have 0.3.1)'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();
    expect(find.text('Version 0.3.2'), findsOneWidget);
    expect(find.textContaining('Notes for v0.3.2', findRichText: true), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Beta'), findsNothing);
    await tester.tap(find.text('Update and restart'));
    await tester.pumpAndSettle();
    expect(installer.installed, ['v0.3.2']);
    expect(find.textContaining("can't be updated from here"), findsOneWidget, reason: 'why it could not');
  });

  testWidgets("the notes are formatted, not raw Markdown", (tester) async {
    server.routes['https://api.github.com/repos/$releasesRepo/releases'] = (200, [
      {...releaseJson('v0.3.2'), 'body': '**Updates in the app:** new\n\n- **Android:** the installer\n- Windows'},
    ]);
    await pumpSection(tester, '0.3.1');
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();
    expect(find.textContaining('**', findRichText: true), findsNothing, reason: 'no raw asterisks');
    expect(find.textContaining('Updates in the app:', findRichText: true), findsOneWidget);
    expect(find.textContaining('•', findRichText: true), findsWidgets, reason: 'a bulleted list');
  });

  testWidgets('Android: back from allowing installs, the update goes on by itself', (tester) async {
    installer.results = [InstallResult.needsPermission, InstallResult.needsPermission];
    final c = container('0.3.1');
    final release = (await tester.runAsync(() => c.read(updateCheckProvider.notifier).check()))!;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => TextButton(onPressed: () => showUpdateDialog(context, release), child: const Text('open'))),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('goes on by itself'), findsOneWidget);

    Future<void> awayAndBack() async {
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused,
          AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();
    }

    // Back without allowing it: says so, nothing more.
    await awayAndBack();
    expect(installer.installed, hasLength(1));
    expect(find.textContaining("isn't allowed yet"), findsOneWidget);

    // Pressed again, allowed this time: back here, it installs on its own.
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    installer.allowed = true;
    await awayAndBack();
    expect(installer.installed, hasLength(3), reason: 'the third without a press');
  });

  testWidgets('Settings: switching to Beta offers the beta', (tester) async {
    await pumpSection(tester, '0.3.2');
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Up to date (0.3.2)'), findsOneWidget);
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(find.text('Version 0.3.3-beta.1 is available (you have 0.3.2)'), findsOneWidget);
  });

  testWidgets('a notification once per new version, with Update', (tester) async {
    final c = container('0.3.1');
    AppRelease? opened;
    final watcher = UpdateWatcher(c, open: (r) => opened = r)..start();
    await tester.pump(UpdateWatcher.firstCheck);
    await tester.pump();
    await tester.runAsync(pumpEventQueue);
    final notes = NotificationHistory.items.value;
    expect(notes.map((n) => n.message), ['Version 0.3.2 is available']);
    notes.single.onAction!();
    expect(opened?.tag, 'v0.3.2');

    await tester.pump(const Duration(hours: 6));
    await tester.runAsync(pumpEventQueue);
    expect(NotificationHistory.items.value, hasLength(1), reason: 'not again for the same version');
    watcher.dispose();
  });

  testWidgets('back in the app after an hour or more: checks again (a phone keeps it open for days)', (tester) async {
    server.routes['https://api.github.com/repos/$releasesRepo/releases'] = (200, [releaseJson('v0.3.1')]);
    final c = container('0.3.1');
    final watcher = UpdateWatcher(c, open: (_) {})..start();
    await tester.pump(UpdateWatcher.firstCheck);
    await tester.runAsync(pumpEventQueue);
    expect(NotificationHistory.items.value, isEmpty, reason: 'up to date');

    Future<void> awayAndBack() async {
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused,
          AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
    }

    // A new version, published meanwhile.
    server.routes['https://api.github.com/repos/$releasesRepo/releases'] = (200, [releaseJson('v0.3.2')]);
    await awayAndBack();
    expect(NotificationHistory.items.value, isEmpty, reason: 'checked only minutes ago');

    // As if the last check were long ago.
    final later = UpdateWatcher(c, open: (_) {}, onReturn: Duration.zero)..start();
    await awayAndBack();
    expect(NotificationHistory.items.value.map((n) => n.message), ['Version 0.3.2 is available']);
    watcher.dispose();
    later.dispose();
  });

  testWidgets('notifications off: still checked, shown in Settings, no toast', (tester) async {
    final c = container('0.3.1', {'update.notify': false});
    final watcher = UpdateWatcher(c, open: (_) {})..start();
    await tester.pump(UpdateWatcher.firstCheck);
    await tester.runAsync(pumpEventQueue);
    expect(c.read(updateCheckProvider).available?.tag, 'v0.3.2');
    expect(NotificationHistory.items.value, isEmpty);
    watcher.dispose();
  });

  testWidgets('Each start: one check, none after; a shorter interval applies at once', (tester) async {
    final c = container('0.3.2', {'update.frequency': 'eachStart'});
    final watcher = UpdateWatcher(c, open: (_) {})..start();
    Future<void> settle() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(UpdateWatcher.firstCheck);
    await settle();
    expect(server.requests, hasLength(1));
    await tester.pump(const Duration(days: 2));
    await settle();
    expect(server.requests, hasLength(1), reason: 'only at start');

    final settings = await c.read(updateSettingsProvider.future);
    await c.read(updateSettingsProvider.notifier).save(settings.copyWith(frequency: UpdateFrequency.hourly));
    await tester.pump(const Duration(minutes: 61));
    await settle();
    expect(server.requests, hasLength(2), reason: 'hourly from now on');
    watcher.dispose();
  });

  testWidgets('refreshing Home checks in the background, at most once a minute', (tester) async {
    final c = container('0.3.1');
    final watcher = UpdateWatcher(c, open: (_) {});
    await tester.runAsync(watcher.refreshed);
    expect(server.requests, hasLength(1));
    expect(NotificationHistory.items.value.map((n) => n.message), ['Version 0.3.2 is available']);
    await tester.runAsync(watcher.refreshed);
    expect(server.requests, hasLength(1), reason: 'checked moments ago');
    watcher.dispose();
  });

  testWidgets('refreshing Home: no check when automatic checks are off', (tester) async {
    final c = container('0.3.1', {'update.autoCheck': false});
    final watcher = UpdateWatcher(c, open: (_) {});
    await tester.runAsync(watcher.refreshed);
    expect(server.requests, isEmpty);
    watcher.dispose();
  });

  test('a failed update says what to do in a line or two, not the raw error', () {
    final dropped = DioException(requestOptions: RequestOptions(path: '/x'), type: DioExceptionType.connectionError,
        message: 'SocketException: ' * 40);
    final message = updateFailedMessage(dropped);
    expect(message, startsWith("The download didn't finish"));
    expect(message, isNot(contains('SocketException')));
    expect(message.length, lessThan(200));
    expect(updateFailedMessage(const FileSystemException('denied')), startsWith("The update couldn't be saved"));
  });

  test('the old on / off setting carries over', () async {
    expect((await container('0.3.1', {'update.autoCheck': false}).read(updateSettingsProvider.future)).frequency,
        UpdateFrequency.manual);
    expect((await container('0.3.1', {'update.autoCheck': true}).read(updateSettingsProvider.future)).frequency,
        UpdateFrequency.sixHours);
  });

  testWidgets('no checks when automatic checks are off', (tester) async {
    final c = container('0.3.1', {'update.autoCheck': false});
    final watcher = UpdateWatcher(c, open: (_) {})..start();
    await tester.pump(UpdateWatcher.firstCheck);
    await tester.runAsync(pumpEventQueue);
    expect(server.requests, isEmpty);
    watcher.dispose();
  });

  test('the Windows script waits, unpacks over the app and opens it again', () {
    final script = windowsUpdateScript(pid: 42, zip: "'C:\\t\\u.zip'", dir: "'C:\\App'", exe: "'C:\\App\\a.exe'", log: "'l'");
    expect(script, contains('Wait-Process -Id 42'));
    expect(script, contains("Expand-Archive -LiteralPath 'C:\\t\\u.zip' -DestinationPath 'C:\\App' -Force"));
    expect(script.trim().split('\n').last, "Start-Process -FilePath 'C:\\App\\a.exe'");
  });
}
