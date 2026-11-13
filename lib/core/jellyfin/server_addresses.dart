import 'dart:async';
import 'dart:io';

/// Whether [address] is on a home network: a private IPv4 address
/// (10.x, 172.16–31.x, 192.168.x), a `.local` or `.home.arpa` name, or a
/// bare name with no dots. Tailscale's 100.64.0.0/10 and public names are not.
bool isHomeAddress(Uri address) {
  final host = address.host.toLowerCase();
  final ip = InternetAddress.tryParse(host);
  if (ip != null) {
    if (ip.type != InternetAddressType.IPv4) return ip.isLinkLocal;
    final b = ip.rawAddress;
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
  }
  return host.endsWith('.local') || host.endsWith('.home.arpa') || !host.contains('.');
}

/// [addresses] in the order to try them: home-network ones first (quicker,
/// and they don't go through the internet), otherwise as saved.
List<Uri> rankAddresses(List<Uri> addresses) {
  final home = [for (final a in addresses) if (isHomeAddress(a)) a];
  return [...home, for (final a in addresses) if (!home.contains(a)) a];
}

/// The address of [addresses] to use: the first (by [rankAddresses]) that
/// answers as server [serverId], asked all at once. Once one answers, those
/// ranked above it get [grace] longer; nothing waits past [timeout]. Null
/// when none answer as that server (a different server at the same address,
/// as on another network, doesn't count).
///
/// [serverIdAt] asks an address which server it is (Jellyfin's public
/// system info), throwing or returning null when it can't.
Future<Uri?> pickAddress(
  List<Uri> addresses,
  String serverId,
  Future<String?> Function(Uri address) serverIdAt, {
  Duration timeout = const Duration(seconds: 4),
  Duration grace = const Duration(milliseconds: 800),
}) async {
  final ranked = rankAddresses(addresses);
  if (ranked.isEmpty) return null;
  // Per address: true = answers as this server, false = doesn't, null = waiting.
  final answers = List<bool?>.filled(ranked.length, null);
  final done = Completer<void>();
  Timer? graceTimer;

  Uri? best() {
    for (var i = 0; i < ranked.length; i++) {
      if (answers[i] == null) return null; // a better one may still answer
      if (answers[i]!) return ranked[i];
    }
    return null;
  }

  void settle() {
    if (done.isCompleted) return;
    if (best() != null || answers.every((a) => a != null)) {
      done.complete();
    } else if (graceTimer == null && answers.contains(true)) {
      graceTimer = Timer(grace, () {
        if (!done.isCompleted) done.complete();
      });
    }
  }

  for (var i = 0; i < ranked.length; i++) {
    unawaited(() async {
      bool ok;
      try {
        ok = await serverIdAt(ranked[i]).timeout(timeout) == serverId;
      } on Object {
        ok = false;
      }
      answers[i] = ok;
      settle();
    }());
  }
  await done.future.timeout(timeout, onTimeout: () {});
  graceTimer?.cancel();
  // The best that answered, skipping those that didn't in time.
  for (var i = 0; i < ranked.length; i++) {
    if (answers[i] ?? false) return ranked[i];
  }
  return null;
}

/// [addresses] with [address] added (if new), without duplicates.
List<Uri> withAddress(List<Uri> addresses, Uri address) =>
    addresses.contains(address) ? addresses : [...addresses, address];
