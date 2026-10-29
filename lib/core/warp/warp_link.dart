import 'warp_profile.dart';
import 'warp_register.dart';

/// The `wireguard://` link of a WARP account for one [method] of the profile, towards [endpoint]'s
/// [portIndex]-th port. A method with noise adds `noise=`: the server is then reached through Xray,
/// which sends the noise before the first packet of the tunnel (see buildXrayConfig).
String warpLink(WarpAccount account, WarpMethod method, WarpEndpoint endpoint, int portIndex,
    {String name = 'WARP'}) {
  final port = endpoint.ports[portIndex % endpoint.ports.length];
  final query = <String, String>{
    'publickey': account.peerPublicKey,
    'address': '${account.v4}/32,${account.v6}/128',
    'mtu': '1280',
    'reserved': account.reserved.join(','),
    if (method.kind == 'wg-noise' && method.noise.isNotEmpty) 'noise': method.noise.map((n) => n.spec).join(','),
  };
  final text = query.entries
      .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return 'wireguard://${Uri.encodeComponent(account.privateKey)}@${endpoint.ip}:$port'
      '?$text#${Uri.encodeComponent(name)}';
}
