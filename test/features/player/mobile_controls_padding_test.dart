import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/player/player_screen.dart';

void main() {
  test('a cutout on one side keeps the controls centred', () {
    final padding = mobileControlsPadding(const EdgeInsets.only(left: 36));
    expect(padding.left, 60);
    expect(padding.right, 60);
    expect(padding.top, padding.bottom);
  });

  test('the gesture bar is kept clear, evenly', () {
    final padding = mobileControlsPadding(const EdgeInsets.only(bottom: 20));
    expect(padding.bottom, 30);
    expect(padding.top, 30);
  });

  test('no insets: just the margins', () {
    expect(mobileControlsPadding(EdgeInsets.zero), const EdgeInsets.symmetric(horizontal: 24, vertical: 10));
  });
}
