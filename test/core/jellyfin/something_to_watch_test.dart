import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/core/jellyfin/items.dart';
import 'package:jellyfin_client/core/jellyfin/library_api.dart';

import '../../support/fake_server.dart';

void main() {
  BaseItem item(String type, Map<String, Object?> userData) =>
      BaseItem.fromJson(itemJson('x', 'X', type: type, extra: {'UserData': userData}));

  test('"Unwatched" means something left to watch', () {
    expect(hasSomethingToWatch(item('Series', {'Played': false, 'UnplayedItemCount': 12})), isTrue);
    expect(hasSomethingToWatch(item('Series', {'Played': true, 'UnplayedItemCount': 0})), isFalse, reason: 'watched');
    expect(hasSomethingToWatch(item('Series', {'Played': false, 'UnplayedItemCount': 0})), isFalse,
        reason: 'no episodes left, just the folder');
    expect(hasSomethingToWatch(item('Series', {'Played': false})), isFalse, reason: 'no episode count: empty');
    expect(hasSomethingToWatch(item('Movie', {'Played': false})), isTrue);
    expect(hasSomethingToWatch(item('Movie', {'Played': true})), isFalse);
  });
}
