import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/layout.dart';
import '../../core/seerr/seerr_api.dart';
import 'seerr_providers.dart';
import 'seerr_screens.dart';
import '../../app/app_dropdown.dart';

/// Where the request window opens (Windows / desktop; phones use a bottom
/// sheet and TVs the centre).
enum RequestWindowStyle {
  centered('In the centre of the screen'),
  fromCard('Next to the card, growing out of it');

  const RequestWindowStyle(this.label);

  final String label;
}

final requestWindowStyleProvider = AsyncNotifierProvider<RequestWindowStyleController, RequestWindowStyle>(
  RequestWindowStyleController.new,
);

class RequestWindowStyleController extends AsyncNotifier<RequestWindowStyle> {
  static const _key = 'seerr.requestWindow';

  @override
  Future<RequestWindowStyle> build() async {
    final name = (await SharedPreferences.getInstance()).getString(_key);
    return RequestWindowStyle.values.where((s) => s.name == name).firstOrNull ?? RequestWindowStyle.centered;
  }

  Future<void> set(RequestWindowStyle style) async {
    state = AsyncData(style);
    await (await SharedPreferences.getInstance()).setString(_key, style.name);
  }
}

/// Whether [media] can be requested by the signed-in Seerr user, as far as
/// a card knows (the window checks the seasons).
bool canRequestFromCard(WidgetRef ref, SeerrMedia media) {
  final user = ref.watch(seerrAccountProvider).value?.user;
  return user != null && user.canRequest(media.type) && media.status.requestable;
}

/// Opens the request form for [media] in a small window: a bottom sheet on
/// phones, centred on TVs, and on desktop centred or (the setting) growing
/// out of [from], the card or button it was opened from.
Future<void> showSeerrRequest(BuildContext context, SeerrMedia media, {Rect? from}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final user = container.read(seerrAccountProvider).value?.user;
  if (user == null) return;
  final body = _RequestWindowBody(type: media.type, tmdbId: media.tmdbId, title: media.title, user: user);
  final form = context.layout.formFactor;
  if (form == FormFactor.phone) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => body,
    );
    return;
  }
  final style = form == FormFactor.tv
      ? RequestWindowStyle.centered
      : await container.read(requestWindowStyleProvider.future).catchError((Object _) => RequestWindowStyle.centered);
  if (!context.mounted) return;
  if (style == RequestWindowStyle.fromCard && from != null) {
    await _showFrom(context, from, body);
  } else {
    await showDialog<void>(
      context: context,
      builder: (_) => _Window(child: body),
    );
  }
}

/// Width of the request window on desktop / TV.
const _windowWidth = 440.0;

class _Window extends StatelessWidget {
  const _Window({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Dialog(
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: _windowWidth, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: Padding(padding: const EdgeInsets.only(top: 20), child: child),
    ),
  );
}

/// The window beside [from] (right of it when there's room, else left),
/// scaling up out of it.
Future<void> _showFrom(BuildContext context, Rect from, Widget body) {
  final screen = MediaQuery.sizeOf(context);
  const gap = 12.0;
  final right = from.right + gap + _windowWidth <= screen.width - 8;
  final left = right ? from.right + gap : math.max(8.0, from.left - gap - _windowWidth);
  // Grows from the card's side, at its middle.
  final origin = Offset(right ? from.right : from.left, from.center.dy);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => Stack(
      children: [
        Positioned(
          left: left,
          top: 0,
          bottom: 0,
          width: _windowWidth,
          child: CustomSingleChildLayout(
            delegate: _BesideCard(from.center.dy),
            child: Material(
              elevation: 8,
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: screen.height * 0.85),
                child: Padding(padding: const EdgeInsets.only(top: 20), child: body),
              ),
            ),
          ),
        ),
      ],
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      // Scale about the point on the card's edge (as a fraction of the
      // window's column, from the screen-sized dialog).
      final alignment = Alignment(((origin.dx - left) / _windowWidth) * 2 - 1, (origin.dy / screen.height) * 2 - 1);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: 0.6, end: 1.0).animate(curved), alignment: alignment, child: child),
      );
    },
  );
}

/// Centres the window on the card's middle, kept on screen.
class _BesideCard extends SingleChildLayoutDelegate {
  _BesideCard(this.centerY);

  final double centerY;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    final top = (centerY - child.height / 2).clamp(8.0, math.max(8.0, size.height - child.height - 8)).toDouble();
    return Offset(0, top);
  }

  @override
  bool shouldRelayout(_BesideCard old) => old.centerY != centerY;
}

/// Loads the title's seasons, then the request form.
class _RequestWindowBody extends ConsumerWidget {
  const _RequestWindowBody({required this.type, required this.tmdbId, required this.title, required this.user});

  final SeerrMediaType type;
  final int tmdbId;
  final String title;
  final SeerrUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(seerrDetailsProvider((type: type, tmdbId: tmdbId)))) {
        AsyncData(:final value) when type == SeerrMediaType.tv && !value.seasons.any((s) => s.status.requestable) =>
          _Note('Every season of $title is requested or on the server already.'),
        AsyncData(:final value) => SeerrRequestSheet(details: value, user: user),
        AsyncError(:final error) => _Note(error is SeerrException ? error.message : "Couldn't load $title: $error"),
        _ => const Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        ),
      };
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(text),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ),
      ],
    ),
  );
}

/// Settings > Seerr: where the request window opens (desktop only).
class RequestWindowSetting extends ConsumerWidget {
  const RequestWindowSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (context.layout.formFactor != FormFactor.desktop) return const SizedBox.shrink();
    final style = ref.watch(requestWindowStyleProvider).value ?? RequestWindowStyle.centered;
    return ListTile(
      leading: const Icon(Icons.open_in_new),
      title: const Text('Request window'),
      subtitle: Text(style.label),
      trailing: AppDropdown<RequestWindowStyle>(
        value: style,
        underline: const SizedBox.shrink(),
        items: [
          for (final s in RequestWindowStyle.values)
            DropdownMenuItem(value: s, child: Text(s == RequestWindowStyle.centered ? 'Centred' : 'From the card')),
        ],
        onChanged: (s) => s == null ? null : ref.read(requestWindowStyleProvider.notifier).set(s),
      ),
    );
  }
}
