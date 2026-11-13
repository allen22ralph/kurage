import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_client/features/home/this_week.dart';

void main() {
  final now = DateTime(2026, 11, 4, 12);

  test('today and tomorrow say so, next to the date', () {
    expect(weekDayTitle(DateTime(2026, 11, 4, 20), 'Wed, Nov 4', now: now), 'Today · Wed, Nov 4');
    expect(weekDayTitle(DateTime(2026, 11, 5, 20), 'Thu, Nov 5', now: now), 'Tomorrow · Thu, Nov 5');
  });

  test('any other day is only the date, not its name twice', () {
    expect(weekDayTitle(DateTime(2026, 11, 6, 20), 'Fri, Nov 6', now: now), 'Fri, Nov 6');
  });
}
