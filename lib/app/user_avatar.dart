import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/jellyfin/jellyfin_api.dart';
import '../core/log/app_log.dart';
import '../features/library/widgets/item_image.dart';
import 'providers.dart';
import 'toast.dart';

/// A user's profile picture in a circle, or their initial when they have
/// none (or it can't be loaded).
class UserAvatar extends ConsumerWidget {
  const UserAvatar({
    super.key,
    required this.baseUrl,
    required this.userId,
    required this.name,
    this.imageTag,
    this.radius = 20,
  });

  final Uri baseUrl;
  final String userId;
  final String name;

  /// The picture's tag from the server; null: no picture.
  final String? imageTag;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initial = CircleAvatar(
      radius: radius,
      child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase()),
    );
    final tag = imageTag;
    if (tag == null) return initial;
    final url = ref
        .read(apiFactoryProvider)(baseUrl)
        .userImageUrl(userId, tag: tag, maxWidth: (radius * 2 * MediaQuery.devicePixelRatioOf(context)).round())
        .toString();
    return SizedBox.square(
      dimension: radius * 2,
      child: ClipOval(
        child: ref.watch(networkImageBuilderProvider)(url, fit: BoxFit.cover, alignment: Alignment.center, fallback: initial),
      ),
    );
  }
}

/// The signed-in user's picture (Home's account button, Settings).
class CurrentUserAvatar extends ConsumerWidget {
  const CurrentUserAvatar({super.key, this.radius = 14});

  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider).value;
    if (session == null) return Icon(Icons.account_circle_outlined, size: radius * 2);
    final user = ref.watch(currentUserProvider).value;
    return UserAvatar(
      baseUrl: session.baseUrl,
      userId: session.userId,
      name: user?.name ?? session.userName,
      imageTag: user?.primaryImageTag,
      radius: radius,
    );
  }
}

/// Picks an image (a file on Windows, the gallery / files on Android) and
/// makes it the signed-in user's picture on the server.
Future<void> changeProfilePicture(WidgetRef ref) async {
  const images = XTypeGroup(
    label: 'Images',
    extensions: ['jpg', 'jpeg', 'png', 'webp'],
    mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
  );
  final file = await openFile(acceptedTypeGroups: const [images]);
  if (file == null) return;
  final bytes = await file.readAsBytes();
  if (bytes.length > 10 * 1024 * 1024) {
    showToast('That picture is over 10 MB: pick a smaller one.');
    return;
  }
  final ext = file.name.split('.').last.toLowerCase();
  final mime = switch (ext) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => 'image/jpeg',
  };
  final session = ref.read(currentSessionProvider);
  try {
    await ref.read(signedInApiProvider).setUserImage(session.userId, bytes, mime);
    ref.invalidate(currentUserProvider);
    ref.invalidate(savedAccountUserProvider);
    AppLog.info(LogArea.app, 'Profile picture changed (${bytes.length ~/ 1024} KB $mime)');
    showToast('Profile picture changed.');
  } on JellyfinException catch (e) {
    AppLog.warning(LogArea.app, "Profile picture couldn't be changed", error: e);
    showToast("Couldn't change the picture: ${e.message}");
  }
}

/// Removes the signed-in user's picture on the server.
Future<void> removeProfilePicture(WidgetRef ref) async {
  final session = ref.read(currentSessionProvider);
  try {
    await ref.read(signedInApiProvider).deleteUserImage(session.userId);
    ref.invalidate(currentUserProvider);
    ref.invalidate(savedAccountUserProvider);
    showToast('Profile picture removed.');
  } on JellyfinException catch (e) {
    showToast("Couldn't remove the picture: ${e.message}");
  }
}
