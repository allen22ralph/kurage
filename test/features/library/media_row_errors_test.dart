import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/core/jellyfin/jellyfin_api.dart';
import 'package:jellyfin_client/features/library/widgets/media_row.dart';

void main() {
  Future<void> pump(WidgetTester tester, {bool hide = false, VoidCallback? onRetry}) => tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: RowErrors(
                hide: hide,
                onRetry: onRetry,
                child: MediaRow(
                  title: 'A row',
                  items: const AsyncError<List<BaseItem>>(JellyfinException('The server took too long to respond.'), StackTrace.empty),
                  onItemPressed: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('a failed row says so plainly and offers to try again', (tester) async {
    var retried = 0;
    await pump(tester, onRetry: () => retried++);
    expect(find.text("Couldn't load this row"), findsOneWidget);
    expect(find.textContaining('JellyfinException'), findsNothing);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
  });

  testWidgets('told to hide, a failed row says nothing', (tester) async {
    await pump(tester, hide: true);
    expect(find.text('A row'), findsNothing);
    expect(find.text("Couldn't load this row"), findsNothing);
  });
}
