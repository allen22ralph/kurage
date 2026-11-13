import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/player/widgets/player_controls.dart';
import 'package:jellyfin_client/features/settings/playback_settings.dart';

void main() {
  testWidgets('a pick counts even when the bar faded out with the menu open', (tester) async {
    final picked = <StreamQuality>[];
    final shown = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomRight,
          child: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (context, on, _) => on
                ? qualityButton(
                    current: () => StreamQuality.original,
                    autoLabel: () => 'Auto',
                    onSelected: picked.add,
                    iconSize: 24,
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ));

    await tester.tap(find.byTooltip('Quality'));
    await tester.pumpAndSettle();
    expect(find.text('4 Mbps'), findsOneWidget);

    // The controls hide: the button is gone, the menu is still open.
    shown.value = false;
    await tester.pump();
    expect(find.byTooltip('Quality'), findsNothing);

    await tester.tap(find.text('4 Mbps'));
    await tester.pumpAndSettle();
    expect(picked, [StreamQuality.mbps4]);
  });
}
