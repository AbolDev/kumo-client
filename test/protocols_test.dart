import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/net_options.dart';
import 'package:kumo/core/proxy_config.dart';
import 'package:kumo/core/singbox_config.dart';
import 'package:kumo/core/sub_formats.dart';

const _key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

Map<String, dynamic> _box(String link) => parseLink(link)!.outbound;

void main() {
  test('AnyTLS, Hysteria 1, SOCKS and SSH links', () {
    final any = _box('anytls://pw@h.example.com:443?sni=a.com&insecure=1#a');
    expect(any['type'], 'anytls');
    expect(any['password'], 'pw');
    expect((any['tls'] as Map)['insecure'], true);

    final h1 = _box('hysteria://h.example.com:443,5000-6000?auth=x&peer=a.com&upmbps=10&obfsParam=o#h');
    expect(h1['type'], 'hysteria');
    expect(h1['up_mbps'], 10);
    expect(h1['down_mbps'], 100);
    expect(h1['auth_str'], 'x');
    expect(h1['obfs'], 'o');
    expect(h1['server_ports'], ['5000:6000']);
    expect(parseLink('hysteria://h.example.com:443?protocol=faketcp&auth=x'), isNull);

    final socks = parseLink('socks5://u:p%40ss@1.2.3.4:1080#s')!;
    expect(socks.outbound['password'], 'p@ss');
    expect(socks.canXray, isTrue);
    expect(_box('socks4://1.2.3.4:1080')['version'], '4');

    final ssh = _box('ssh://user:pass@1.2.3.4#x');
    expect(ssh['type'], 'ssh');
    expect(ssh['server_port'], 22);
    expect(parseLink('ssh://1.2.3.4'), isNull);
  });

  test('Telegram proxy links become SOCKS links', () {
    final text = convertTelegramProxyLinks(
        'see https://t.me/socks?server=1.2.3.4&port=1080&user=u&pass=p and tg://socks?server=5.6.7.8&port=443');
    expect(text, contains('socks5://u:p@1.2.3.4:1080'));
    expect(text, contains('socks5://5.6.7.8:443'));
    expect(extractLinks(text), hasLength(2));
  });

  test('WireGuard link and configuration file', () {
    final link = 'wireguard://${Uri.encodeComponent(_key)}@1.2.3.4:51820?publickey=${Uri.encodeComponent(_key)}'
        '&address=10.0.0.2&reserved=1,2,3&mtu=1280#wg';
    final c = parseLink(link)!;
    expect(c.outbound['type'], 'wireguard');
    expect(c.outbound['address'], ['10.0.0.2/32']);
    final peer = (c.outbound['peers'] as List).single as Map;
    expect(peer['reserved'], [1, 2, 3]);
    expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
    final xray = c.xrayOutbound!['settings'] as Map;
    expect((xray['peers'] as List).single['endpoint'], '1.2.3.4:51820');
    expect(parseLink('wireguard://k@1.2.3.4:51820?address=10.0.0.2'), isNull);

    final conf = '[Interface]\nPrivateKey = $_key\nAddress = 10.0.0.2/32, fd00::2/128\nMTU = 1280\n'
        '[Peer]\nPublicKey = $_key\nEndpoint = h.example.com:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n';
    final links = extractSubscriptionLinks(conf);
    expect(links, hasLength(1));
    final fromConf = parseLink(links.single)!;
    expect((fromConf.outbound['address'] as List).length, 2);
    expect(((fromConf.outbound['peers'] as List).single as Map)['address'], 'h.example.com');

    final cfg = jsonDecode(buildSingBoxConfig([c])) as Map<String, dynamic>;
    // WireGuard is an endpoint in sing-box, used by its tag.
    expect((cfg['endpoints'] as List).single['tag'], 'proxy');
    expect(cfg['route']['final'], 'proxy');
  });

  test('Shadowsocks plugins', () {
    final user = base64Url.encode(utf8.encode('aes-256-gcm:secret')).replaceAll('=', '');
    String plugin(String p) => 'ss://$user@h.example.com:8388?plugin=${Uri.encodeComponent(p)}#a';
    final obfs = _box(plugin('obfs-local;obfs=http;obfs-host=x.com'));
    expect(obfs['plugin'], 'obfs-local');
    expect(obfs['plugin_opts'], 'obfs=http;obfs-host=x.com');
    expect(_box(plugin('v2ray-plugin;tls;host=x.com'))['plugin'], 'v2ray-plugin');
    expect(parseLink(plugin('kcptun;key=1')), isNull);

    final tls = parseLink(plugin('shadow-tls;host=cloud.tencent.com;passwd=pw;version=3'))!;
    expect(tls.inner.single['type'], 'shadowtls');
    expect(tls.inner.single['password'], 'pw');
    final cfg = jsonDecode(buildSingBoxConfig([tls])) as Map<String, dynamic>;
    final byTag = {for (final o in cfg['outbounds'] as List) o['tag']: o};
    expect(byTag['proxy']['detour'], 'proxy-l1');
    expect(byTag['proxy-l1']['type'], 'shadowtls');
    // Plain Shadowsocks can also run on Xray; with a plugin it cannot.
    expect(parseLink('ss://$user@h.example.com:8388#a')!.canXray, isTrue);
    expect(tls.canXray, isFalse);
  });

  test('what only Xray can carry goes to Xray', () {
    final enc = parseLink('vless://id@h.example.com:443?security=tls&sni=a.com'
        '&encryption=mlkem768x25519plus.native.0rtt.KEY#a')!;
    expect(enc.needsXray, isTrue);
    expect(enc.label, 'vless + encryption');
    final user = ((enc.xrayOutbound!['settings'] as Map)['vnext'] as List).single['users'].single;
    expect(user['encryption'], startsWith('mlkem768x25519plus'));

    final header = parseLink('vless://id@h.example.com:80?type=tcp&headerType=http&host=a.com&path=%2Fx')!;
    expect(header.needsXray, isTrue);
    expect(header.label, 'vless + http header');
    final raw = (header.xrayOutbound!['streamSettings'] as Map)['rawSettings'] as Map;
    expect(raw['header']['request']['headers']['Host'], ['a.com']);
    expect(raw['header']['request']['path'], ['/x']);

    final kcp = parseLink('vless://id@h.example.com:443?type=kcp&headerType=wechat-video&seed=abc')!;
    final mask = (kcp.xrayOutbound!['streamSettings'] as Map)['finalmask'] as Map;
    expect(mask['udp'].single['type'], 'mkcp-legacy');
    expect(mask['udp'].single['settings'], {'header': 'wechat', 'value': 'abc'});

    // Both cores: sing-box first, Xray when chosen.
    final ws = parseLink('trojan://pw@h.example.com:443?security=tls&sni=a.com&type=ws&path=%2Fw')!;
    expect(ws.canSingBox && ws.canXray, isTrue);
    expect(ws.needsXray, isFalse);
    // QUIC transport is sing-box only.
    final quic = parseLink('vmess://${base64.encode(utf8.encode(jsonEncode({'add': 'h.com', 'port': '443', 'id': 'u', 'net': 'quic', 'tls': 'tls'})))}')!;
    expect(quic.canSingBox, isTrue);
    expect(quic.canXray, isFalse);
  });

  test('websocket early data, ECH, TUIC and Hysteria 2 extras', () {
    final ws = _box('vless://id@h.example.com:443?security=tls&sni=a.com&type=ws&path=%2Fp%3Fed%3D2048&host=a.com');
    final t = ws['transport'] as Map;
    expect(t['path'], '/p');
    expect(t['max_early_data'], 2048);
    expect(t['early_data_header_name'], 'Sec-WebSocket-Protocol');

    final ech = _box('vless://id@h.example.com:443?security=tls&sni=a.com&ech=cloudflare-ech.com%2Bhttps%3A%2F%2F1.1.1.1%2Fdns-query');
    expect((ech['tls'] as Map)['ech'], {'enabled': true, 'query_server_name': 'cloudflare-ech.com'});

    final tuic = _box('tuic://uuid:pw@h.example.com:443?sni=a.com&disable_sni=1&zero_rtt_handshake=1&heartbeat=10&udp_over_stream=1');
    expect(tuic['zero_rtt_handshake'], true);
    expect(tuic['heartbeat'], '10s');
    expect(tuic['udp_over_stream'], true);
    expect(tuic.containsKey('udp_relay_mode'), false);
    expect((tuic['tls'] as Map)['disable_sni'], true);

    final hy2 = parseLink('hysteria2://pw@h.example.com:443,5000-6000?obfs=salamander&obfs-password=op'
        '&upmbps=20&downmbps=100&hop-interval=30')!;
    expect(hy2.outbound['up_mbps'], 20);
    expect(hy2.outbound['hop_interval'], '30s');
    final xr = hy2.xrayOutbound!;
    expect(xr['protocol'], 'hysteria');
    final stream = xr['streamSettings'] as Map;
    expect(stream['network'], 'hysteria');
    expect(stream['finalmask']['udp'].single['type'], 'salamander');
    expect(stream['finalmask']['quicParams']['udpHop']['ports'], '5000-6000');
  });

  test('the options of Settings reach the sing-box configuration', () {
    final servers = parseLinks(['trojan://pw@h.example.com:443?security=tls&sni=a.com&type=ws&path=%2Fw']);
    final o = NetOptions()
      ..mux = true
      ..muxProtocol = 'yamux'
      ..tlsFragment = true
      ..tlsRecordFragment = true
      ..tcpFastOpen = true
      ..connectTimeout = 7
      ..certStore = 'mozilla'
      ..ntp = true
      ..fakeIp = true
      ..tun = true
      ..networkStrategy = 'fallback'
      ..directWifi = ['Home']
      ..blockRules = ['ads.example.com', 'port:25']
      ..directRules = ['full:www.a.com', 'keyword:cdn', 'regex:^ad[0-9]+\\.', 'port:1000-2000']
      ..extraSingbox = '{"tcp_keep_alive":"30s","tag":"ignored"}'
      ..customDns = 'quic://dns.adguard-dns.com'
      ..dns = 'custom';
    final cfg = jsonDecode(buildSingBoxConfig(servers, options: o)) as Map<String, dynamic>;
    final proxy = (cfg['outbounds'] as List).first as Map;
    expect(proxy['multiplex'], {'enabled': true, 'protocol': 'yamux', 'padding': true});
    expect(proxy['tls']['record_fragment'], true);
    expect(proxy['tcp_fast_open'], true);
    expect(proxy['connect_timeout'], '7s');
    expect(proxy['tcp_keep_alive'], '30s');
    expect(proxy['tag'], 'proxy');
    expect(cfg['certificate'], {'store': 'mozilla'});
    expect(cfg['ntp']['enabled'], true);
    expect(cfg['route']['default_network_strategy'], 'fallback');
    final rules = (cfg['route']['rules'] as List).cast<Map>();
    expect(rules.where((r) => r['action'] == 'reject').length, 2);
    expect(rules.any((r) => r['domain'] != null && r['outbound'] == 'direct'), true);
    expect(rules.any((r) => r['port_range'] != null), true);
    expect(rules.any((r) => r['wifi_ssid'] != null), false);
    final dns = cfg['dns'] as Map;
    expect((dns['servers'] as List).first['type'], 'quic');
    expect((dns['servers'] as List).any((s) => s['type'] == 'fakeip'), true);
    expect(cfg['experimental']['cache_file']['store_fakeip'], true);
    // Windows has no Wi-Fi rule and no network strategy.
    final win = jsonDecode(buildSingBoxConfig(servers, options: o, windows: true)) as Map<String, dynamic>;
    expect((win['route']['rules'] as List).any((r) => r['wifi_ssid'] != null), false);
    expect(win['route'].containsKey('default_network_strategy'), false);
  });

  test('Xray takes the options of Settings too', () {
    final c = parseLink('vless://id@h.example.com:443?security=tls&sni=a.com&type=ws&path=%2Fw')!;
    final o = NetOptions()
      ..mux = true
      ..tlsFragment = true
      ..tcpFastOpen = true
      ..fingerprint = 'firefox'
      ..extraXray = '{"sockopt":{"tcpNoDelay":true}}';
    final cfg = jsonDecode(buildXrayConfig(c, 31000, options: o)) as Map<String, dynamic>;
    final out = (cfg['outbounds'] as List).first as Map;
    expect(out['mux']['enabled'], true);
    final stream = out['streamSettings'] as Map;
    expect(stream['tlsSettings']['fingerprint'], 'firefox');
    expect(stream['sockopt'], {'tcpFastOpen': true, 'tcpNoDelay': true});
    expect(stream['finalmask']['tcp'].single['type'], 'fragment');
    // Run through Xray by the choice of core: sing-box reaches it over a local SOCKS port.
    final box = jsonDecode(buildSingBoxConfig([c], xrayPort: 31000, viaXray: true)) as Map<String, dynamic>;
    final proxy = (box['outbounds'] as List).first as Map;
    expect(proxy['type'], 'socks');
    expect(proxy['server_port'], 31000);
  });

  test('extra JSON is merged without replacing whole objects', () {
    expect(mergeJson({'a': {'b': 1, 'c': 2}, 'd': 1}, {'a': {'b': 9}, 'e': 3}),
        {'a': {'b': 9, 'c': 2}, 'd': 1, 'e': 3});
    expect(parseExtraJson('  '), isNull);
    expect(parseExtraJson('[1]'), isNull);
    expect(parseExtraJson('{"a":1}'), {'a': 1});
  });

  test('routing rule kinds', () {
    final o = NetOptions()
      ..load({
        'directRules': ['Example.com', 'full:WWW.a.com', 'keyword:Ads', 'port:80-90', 'bogus!'],
      });
    expect(o.directRules, ['example.com', 'full:www.a.com', 'keyword:ads', 'port:80-90']);
  });
}
