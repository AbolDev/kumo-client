import 'cloudflare_colos.dart';
import 'ip_info.dart';
import 'operator_names.dart';
import 'speed_test.dart' show SpeedServer;

/// What a node of the path is: the user's own network, the exit of the VPN, the test server.
enum PathKind { you, exit, server }

/// One node of the path card of the speed test: its kind, the name (an operator with its known name, a provider) and
/// the lines under it (the place, the address).
class PathNode {
  const PathNode(this.kind, this.title, this.lines);

  final PathKind kind;
  final String title;
  final List<String> lines;
}

/// "Tehran, Iran" of an address's place; empty when nothing is known.
String ipPlace(IpInfo i) =>
    [i.city, i.country].where((e) => e != null && e.trim().isNotEmpty).map((e) => e!.trim()).toSet().join(', ');

/// The name of the operator of [i] with its known name after it.
String ipOperator(IpInfo i) => operatorLabel(isp: i.isp, asn: i.asn) ?? '';

/// The nodes of the path of a test, in the order the traffic goes: the user's own network (when it is known), the exit
/// of the VPN (with a VPN on), the test server. Without a VPN the connection's own address is the user's network.
/// [colo] is the Cloudflare data center the test reached.
List<PathNode> buildPath({
  required IpView? view,
  required bool viaVpn,
  required SpeedServer server,
  String? colo,
}) {
  PathNode node(PathKind kind, IpInfo i) => PathNode(kind, ipOperator(i), [
        ipPlace(i),
        i.v4 ?? i.v6 ?? '',
      ].where((e) => e.isNotEmpty).toList());

  final nodes = <PathNode>[];
  final mine = view?.mine;
  final exit = view?.exit;
  if (viaVpn) {
    if (mine != null) nodes.add(node(PathKind.you, mine));
    if (exit != null) nodes.add(node(PathKind.exit, exit));
  } else if (exit != null) {
    nodes.add(node(PathKind.you, exit));
  }
  final place = server.id == 'cloudflare' ? (colo == null ? null : coloLabel(colo)) : server.place;
  nodes.add(PathNode(PathKind.server, server.provider.isEmpty ? server.name : server.provider, [if (place != null) place]));
  return nodes;
}
