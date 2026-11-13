import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/jellyfin/admin_api.dart';

final adminApiProvider = Provider<AdminApi>((ref) => AdminApi(ref.watch(signedInApiProvider)));

/// Whether the signed-in user administers the server (server controls are
/// shown only then). False when signed out or the server can't be asked.
final isAdminProvider = FutureProvider<bool>(
  (ref) async => (await ref.watch(currentUserProvider.future))?.isAdministrator ?? false,
);

final serverInfoProvider = FutureProvider.autoDispose<ServerInfo>((ref) => ref.watch(adminApiProvider).serverInfo());

final scheduledTasksProvider =
    FutureProvider.autoDispose<List<ScheduledTask>>((ref) => ref.watch(adminApiProvider).scheduledTasks());

final adminUsersProvider = FutureProvider.autoDispose<List<AdminUser>>((ref) => ref.watch(adminApiProvider).users());

final serverLibrariesProvider =
    FutureProvider.autoDispose<List<({String id, String name})>>((ref) => ref.watch(adminApiProvider).libraries());

final parentalRatingsProvider = FutureProvider.autoDispose<List<({String name, int value})>>(
  (ref) => ref.watch(adminApiProvider).parentalRatings().catchError((Object _) => <({String name, int value})>[]),
);

/// Devices signed in to the server: one user's, or everyone's (null).
final serverDevicesProvider = FutureProvider.autoDispose.family<List<ServerDevice>, String?>(
  (ref, userId) => ref.watch(adminApiProvider).devices(userId: userId),
);
