import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'server_addresses.dart';

/// A Jellyfin server found on the local network.
class DiscoveredServer {
  const DiscoveredServer({required this.id, required this.name, required this.address});

  final String id;
  final String name;
  final Uri address;
}

/// Asks [address] which Jellyfin server it is (its public system info):
/// (id, name), or null when it isn't one or doesn't answer.
typedef ServerProbe = Future<({String id, String name})?> Function(Uri address);

/// Finds Jellyfin servers on the local network, each once, as they answer:
///
/// - Jellyfin's own discovery: "Who is JellyfinServer?" broadcast to UDP
///   7359 (answered when the server allows it and isn't behind Docker's
///   network);
/// - with [scan], also a scan of this device's local networks for
///   Jellyfin's usual port, 8096, for servers that don't answer the
///   broadcast. Only when asked for: on someone else's network (work, a
///   hotel) a scan can look like an attack.
///
/// Done after [timeout].
Stream<DiscoveredServer> discoverServers({
  required ServerProbe probe,
  bool scan = false,
  Duration timeout = const Duration(seconds: 6),
  int port = 8096,
}) {
  final out = StreamController<DiscoveredServer>();
  final seen = <String>{};
  var closed = false;

  void found(DiscoveredServer server) {
    if (closed || !seen.add(server.id)) return;
    out.add(server);
  }

  Future<void> run() async {
    final interfaces = await _homeInterfaces();
    final deadline = Timer(timeout, () {});
    await Future.wait([
      _broadcast(interfaces, timeout, found).catchError((Object _) {}),
      if (scan) _scan(interfaces, port, probe, found, () => !deadline.isActive || closed).catchError((Object _) {}),
    ]).timeout(timeout, onTimeout: () => const []);
    deadline.cancel();
    closed = true;
    await out.close();
  }

  out.onListen = () => unawaited(run());
  out.onCancel = () => closed = true;
  return out.stream;
}

/// This device's IPv4 addresses on home networks (not Tailscale or the
/// internet), Wi-Fi and Ethernet first, at most four.
Future<List<InternetAddress>> _homeInterfaces() async {
  final List<NetworkInterface> all;
  try {
    all = await NetworkInterface.list(type: InternetAddressType.IPv4);
  } on Object {
    return const [];
  }
  bool likely(NetworkInterface i) {
    final n = i.name.toLowerCase();
    return n.contains('wi-fi') || n.contains('wlan') || n.contains('ethernet') || n.startsWith('eth') || n.startsWith('en');
  }

  final ordered = [...all.where(likely), ...all.where((i) => !likely(i))];
  return [
    for (final i in ordered)
      for (final a in i.addresses)
        if (!a.isLoopback && isHomeAddress(Uri(host: a.address))) a,
  ].take(4).toList();
}

Future<void> _broadcast(List<InternetAddress> interfaces, Duration timeout, void Function(DiscoveredServer) found) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final ask = utf8.encode('Who is JellyfinServer?');
  final targets = {
    InternetAddress('255.255.255.255'),
    // Each network's own broadcast address too (x.y.z.255), which some
    // routers and systems pass when they drop the general one.
    for (final a in interfaces) InternetAddress('${a.address.substring(0, a.address.lastIndexOf('.'))}.255'),
  };
  for (final t in targets) {
    try {
      socket.send(ask, t, 7359);
    } on Object {
      // Not allowed on this network: the scan still runs.
    }
  }
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    try {
      final json = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
      final id = json['Id'] as String?;
      final address = Uri.tryParse(json['Address'] as String? ?? '');
      if (id == null || address == null || address.host.isEmpty) return;
      // A server in Docker can give its container's address; the one that
      // answered is reachable for sure.
      final usable = isHomeAddress(address) && address.host != '::1' && !address.host.startsWith('127.')
          ? address
          : address.replace(host: datagram.address.address);
      found(DiscoveredServer(id: id, name: json['Name'] as String? ?? 'Jellyfin', address: usable));
    } on Object {
      // Not a Jellyfin answer.
    }
  });
  await Future<void>.delayed(timeout);
  await sub.cancel();
  socket.close();
}

/// Tries [port] on every address of each home network (as /24s), a few
/// dozen at a time, asking those that accept which server they are.
Future<void> _scan(
  List<InternetAddress> interfaces,
  int port,
  ServerProbe probe,
  void Function(DiscoveredServer) found,
  bool Function() stop,
) async {
  final hosts = <String>[
    for (final a in interfaces)
      for (var n = 1; n <= 254; n++)
        if ('${a.address.substring(0, a.address.lastIndexOf('.'))}.$n' case final h when h != a.address) h,
  ];
  var next = 0;
  Future<void> worker() async {
    while (next < hosts.length && !stop()) {
      final host = hosts[next++];
      try {
        final socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 700));
        socket.destroy();
      } on Object {
        continue;
      }
      final address = Uri(scheme: 'http', host: host, port: port);
      final server = await probe(address).catchError((Object _) => null);
      if (server != null) found(DiscoveredServer(id: server.id, name: server.name, address: address));
    }
  }

  await Future.wait([for (var i = 0; i < 64; i++) worker()]);
}
