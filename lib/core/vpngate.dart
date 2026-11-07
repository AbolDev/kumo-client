import 'sources.dart';

/// The OpenVPN servers of VPN Gate (run by volunteers, University of Tsukuba), all of them. vpngate.net itself
/// cannot be opened from Iran, so a repository (github.com/AbolDev/vpngate-mirror) copies the list every few
/// hours and it is taken from GitHub and its mirrors.
const kVpnGateSources = <String>[
  'https://cdn.jsdelivr.net/gh/AbolDev/vpngate-mirror@main/servers.txt',
  'https://gcore.jsdelivr.net/gh/AbolDev/vpngate-mirror@main/servers.txt',
  'https://fastly.jsdelivr.net/gh/AbolDev/vpngate-mirror@main/servers.txt',
  'https://raw.githubusercontent.com/AbolDev/vpngate-mirror/main/servers.txt',
];

/// What the servers of this list are called (the name starts with the flag; the text marks them so a
/// refresh can replace the earlier ones).
const vpnGateMark = 'VPN Gate';

Future<List<String>> fetchVpnGate() async => (await fetchFromSources(sources: kVpnGateSources)).links;
