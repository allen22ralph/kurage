import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../core/log/app_log.dart';

/// Test builds only (--dart-define=CLICK_LOG=true; never in a release, as
/// nothing else passes it): each press and release as it reaches the app, and
/// what's under it. For clicks that stop working: this says whether they get
/// here at all, how the buttons read, and what they land on.
void logClicks() {
  final dispatcher = PlatformDispatcher.instance;
  final next = dispatcher.onPointerDataPacket;
  var movingHeld = false;
  dispatcher.onPointerDataPacket = (packet) {
    for (final d in packet.data) {
      if (d.kind != PointerDeviceKind.mouse) continue;
      switch (d.change) {
        case PointerChange.down:
          AppLog.info(LogArea.app, 'Click: press, buttons ${d.buttons}, on ${_under(d)}');
        case PointerChange.up:
          movingHeld = false;
          AppLog.info(LogArea.app, 'Click: release, buttons ${d.buttons}');
        case PointerChange.cancel:
          movingHeld = false;
          AppLog.info(LogArea.app, 'Click: cancelled');
        case PointerChange.move when d.buttons != 0 && !movingHeld:
          // (Once: a drag sends many.)
          movingHeld = true;
          AppLog.info(LogArea.app, 'Click: moving with buttons ${d.buttons} held');
        case PointerChange.hover when movingHeld:
          movingHeld = false;
          AppLog.info(LogArea.app, 'Click: moving with none held again');
        default:
      }
    }
    next?.call(packet);
  };
}

/// The innermost few things at the pointer.
String _under(PointerData d) {
  final view = WidgetsBinding.instance.platformDispatcher.view(id: d.viewId);
  if (view == null) return 'no window';
  final at = Offset(d.physicalX, d.physicalY) / view.devicePixelRatio;
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, at, d.viewId);
  final names = [for (final e in result.path.take(4)) e.target.runtimeType.toString()];
  return '(${at.dx.round()}, ${at.dy.round()}) ${names.join(' < ')}';
}
