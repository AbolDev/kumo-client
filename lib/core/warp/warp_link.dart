import 'warp_profile.dart';
import 'warp_register.dart';

/// The `warp-masque://` link of a MASQUE account for the MASQUE [method] (`masque-h2` or `masque-h3`).
///
/// [fingerprint] is the uTLS fingerprint of the TLS hello (`chrome`, `firefox`, ...); empty keeps Xray's own.
/// Xray applies it over HTTP/2 only.
String masqueLink(WarpMasqueAccount account, WarpMethod method,
    {String? endpoint, String name = 'WARP', String fingerprint = ''}) {
  final h3 = method.kind == 'masque-h3';
  final query = {
    'priv': account.privateKey,
    'pub': account.edgeKey,
    'address': '${account.v4}/32,${account.v6}/128',
    'alpn': h3 ? 'h3' : 'h2',
    'sni': masqueSniFor(method),
    if (fingerprint.isNotEmpty) 'fp': fingerprint,
  };
  final text = query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
  return 'warp-masque://${endpoint ?? account.endpoint}:443?$text#${Uri.encodeComponent('$name ${method.id}')}';
}

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
