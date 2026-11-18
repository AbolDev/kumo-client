import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/cloudflare_colos.dart';
import 'package:kumo/core/ip_info.dart';
import 'package:kumo/core/network_path.dart';
import 'package:kumo/core/operator_names.dart';
import 'package:kumo/core/speed_test.dart';

const _mci = IpInfo(
    v4: '5.213.129.22', country: 'Iran', countryCode: 'IR', city: 'Tehran', isp: 'Mobile Communication Company of Iran PLC', asn: 'AS197207');
const _hetzner = IpInfo(v4: '46.8.102.122', country: 'Germany', countryCode: 'DE', city: 'Falkenstein', isp: 'Hetzner Online GmbH', asn: 'AS24940');

void main() {
  group('the known name of an operator', () {
    test('comes after the registered name; the number of the network decides first', () {
      expect(operatorLabel(isp: 'Mobile Communication Company of Iran PLC', asn: 'AS197207'), 'Mobile Communication Company of Iran PLC (MCI, Hamrah Aval)');
      expect(operatorBrand(isp: 'something else entirely', asn: 'AS44244'), 'Irancell');
      expect(operatorBrand(isp: 'Iran Cell Service and Communication Company'), 'Irancell');
    });

    test('is left out for a company the table does not know, and when the name already says it', () {
      expect(operatorLabel(isp: 'Hetzner Online GmbH', asn: 'AS24940'), 'Hetzner Online GmbH');
      expect(operatorLabel(isp: null), isNull);
      expect(operatorLabel(isp: 'Rightel Communication Service Company PJS', asn: 'AS57218'), 'Rightel Communication Service Company PJS');
    });
  });

  group('the two views of the connection', () {
    test('without a VPN it is the user\'s own network, as it always was', () {
      final v = chooseIpView(_mci, null, connected: false);
      expect(v.exit!.v4, _mci.v4);
      expect(v.mine, isNull);
    });

    test('with a VPN, an Iranian address the others did not see is the user\'s own network', () {
      final v = chooseIpView(_hetzner, _mci, connected: true);
      expect(v.exit!.isp, 'Hetzner Online GmbH');
      expect(v.mine!.v4, _mci.v4);
    });

    test('with a VPN, the same address, a foreign answer or no answer gives no second view', () {
      expect(chooseIpView(_mci, _mci, connected: true).mine, isNull, reason: 'the VPN server is in Iran');
      expect(chooseIpView(_hetzner, const IpInfo(v4: '9.9.9.9', countryCode: 'DE'), connected: true).mine, isNull);
      expect(chooseIpView(_hetzner, null, connected: true).mine, isNull);
      final onlyMine = chooseIpView(null, _mci, connected: true);
      expect(onlyMine.exit, isNull);
      expect(onlyMine.mine, isNotNull);
    });

    test('the Iranian service tells the network number too', () {
      final j = parseIranInfo({
        'status': 'success',
        'query': '5.213.129.22',
        'countryCode': 'IR',
        'isp': 'Mobile Communication Company of Iran PLC',
        'as': 'AS197207 Mobile Communication Company of Iran PLC',
      })!;
      expect(j.asn, 'AS197207');
    });
  });

  group('the data center of Cloudflare', () {
    test('is read from the header and from the trace', () {
      expect(coloOfRay('a5c788ec2d54d19f-MCI'), 'MCI');
      expect(coloOfRay('nothing'), isNull);
      expect(coloOfTrace('fl=1\nip=1.2.3.4\ncolo=fra\nloc=DE\n'), 'FRA');
      expect(coloOfTrace('ip=1.2.3.4'), isNull);
    });

    test('is a city when the table has one, the code when it has not', () {
      expect(coloLabel('FRA'), 'Frankfurt (FRA)');
      expect(coloLabel('mci'), 'Kansas City (MCI)');
      expect(coloLabel('QQQ'), 'QQQ');
    });
  });

  group('the path of a test', () {
    final cloudflare = speedServerById('cloudflare');

    test('with a VPN: the user\'s network, the exit, the server', () {
      final nodes = buildPath(view: IpView(exit: _hetzner, mine: _mci), viaVpn: true, server: cloudflare, colo: 'FRA');
      expect(nodes.map((n) => n.kind), [PathKind.you, PathKind.exit, PathKind.server]);
      expect(nodes[0].title, 'Mobile Communication Company of Iran PLC (MCI, Hamrah Aval)');
      expect(nodes[0].lines, ['Tehran, Iran', '5.213.129.22']);
      expect(nodes[1].title, 'Hetzner Online GmbH');
      expect(nodes[2].title, 'Cloudflare');
      expect(nodes[2].lines, ['Frankfurt (FRA)']);
    });

    test('without a VPN: the connection is the user\'s own network; there is no exit', () {
      final nodes = buildPath(view: IpView(exit: _mci), viaVpn: false, server: cloudflare, colo: 'FRA');
      expect(nodes.map((n) => n.kind), [PathKind.you, PathKind.server]);
    });

    test('a server with one place says it, and a path nobody could ask for still names the server', () {
      final ovh = speedServerById('ovh');
      final nodes = buildPath(view: null, viaVpn: true, server: ovh);
      expect(nodes.single.kind, PathKind.server);
      expect(nodes.single.title, 'OVH');
      expect(nodes.single.lines, ['Roubaix, France']);
      expect(buildPath(view: null, viaVpn: false, server: cloudflare).single.lines, isEmpty, reason: 'no data center known');
    });
  });
}
