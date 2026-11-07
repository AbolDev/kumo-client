import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/config_decryptor.dart';
import 'package:kumo/core/proxy_config.dart';

const _fragment = {
  'tcp': [
    {
      'type': 'fragment',
      'settings': {'delay': '10-20', 'length': '6-14', 'maxSplit': '10', 'packets': 'tlshello'},
    },
  ],
  'udp': [
    {
      'type': 'noise',
      'settings': {
        'noise': [
          {'delay': '10-16', 'rand': '10-20'},
        ],
      },
    },
  ],
};

String _line(Map<String, dynamic> stream, {String protocol = 'vless', Map<String, dynamic>? settings}) {
  final cfg = {
    'outbounds': [
      {
        'protocol': protocol,
        'tag': 'proxy',
        'settings': settings ??
            {
              'address': 'h.example.com',
              'port': '443',
              'id': 'd342d11e-d224-4463-b982-532309285094',
              'encryption': 'none',
              'flow': '',
              'level': '8',
            },
        'streamSettings': stream,
        'mux': {'enabled': 'false', 'concurrency': '-1'},
      },
      {'protocol': 'freedom', 'tag': 'direct'},
    ],
  };
  return 'addedTime=1 remarks=NL 1 server=h.example.com serverPort=443 v2rayJson=${jsonEncode(cfg)}';
}

void main() {
  test('the text "false" is not a flag: a TLS server is not made insecure and gRPC is not made multi', () {
    final links = v2rayLineLinks(_line({
      'network': 'grpc',
      'security': 'tls',
      'tlsSettings': {'allowInsecure': 'false', 'serverName': 'h.example.com'},
      'grpcSettings': {'serviceName': 'svc', 'multiMode': 'false'},
    }));
    expect(links, hasLength(1));
    final q = Uri.parse(links.single).queryParameters;
    expect(q.containsKey('allowInsecure'), isFalse);
    expect(q['mode'], 'gun');
    // and the text "true" is one
    final on = v2rayLineLinks(_line({
      'network': 'grpc',
      'security': 'tls',
      'tlsSettings': {'allowInsecure': 'true', 'serverName': 'h.example.com'},
      'grpcSettings': {'serviceName': 'svc', 'multiMode': 'true'},
    }));
    final qo = Uri.parse(on.single).queryParameters;
    expect(qo['allowInsecure'], '1');
    expect(qo['mode'], 'multi');
  });

  test('the final mask, the socket options and the gRPC timings are kept, and Xray carries the server', () {
    final links = v2rayLineLinks(_line({
      'network': 'grpc',
      'security': 'tls',
      'finalmask': _fragment,
      'sockopt': {
        'domainStrategy': 'UseIP',
        'happyEyeballs': {'interleave': '2', 'maxConcurrentTry': '4', 'prioritizeIPv6': 'false', 'tryDelayMs': '250'},
      },
      'tlsSettings': {'serverName': 'h.example.com', 'fingerprint': 'firefox'},
      'grpcSettings': {'serviceName': 'svc', 'multiMode': 'false', 'idle_timeout': '60', 'health_check_timeout': '20'},
    }));
    final c = parseLinks(links).single;
    expect(c.preferXray, isTrue);
    expect(c.canSingBox, isTrue, reason: 'it still works in the automatic group');
    final stream = c.xrayOutbound!['streamSettings'] as Map;
    expect(stream['finalmask'], _fragment);
    final so = stream['sockopt'] as Map;
    expect(so['domainStrategy'], 'UseIP');
    expect((so['happyEyeballs'] as Map)['interleave'], 2);
    expect((so['happyEyeballs'] as Map)['prioritizeIPv6'], false);
    final grpc = stream['grpcSettings'] as Map;
    expect(grpc['idle_timeout'], 60);
    expect(grpc['health_check_timeout'], 20);
    expect(grpc['multiMode'], false);
  });

  test('a server without a final mask is not forced onto Xray', () {
    final c = parseLinks(v2rayLineLinks(_line({
      'network': 'tcp',
      'security': 'tls',
      'tlsSettings': {'serverName': 'h.example.com'},
    }))).single;
    expect(c.preferXray, isFalse);
  });

  test('a VMess server keeps its final mask too', () {
    final links = v2rayLineLinks(_line(
      {'network': 'tcp', 'security': 'none', 'finalmask': _fragment, 'tcpSettings': {'header': {'type': 'none'}}},
      protocol: 'vmess',
      settings: {'address': 'h.example.com', 'port': '443', 'id': 'c430cc57-5dfe-4406-8bc6-21be059b2cd8', 'security': 'auto'},
    ));
    final c = parseLinks(links).single;
    expect(c.protocol, 'vmess');
    expect(c.preferXray, isTrue);
    expect((c.xrayOutbound!['streamSettings'] as Map)['finalmask'], _fragment);
  });

  test('two servers that differ only in their final mask are two servers', () {
    final a = parseLinks(v2rayLineLinks(_line({'network': 'tcp', 'security': 'none', 'finalmask': _fragment}))).single;
    final other = {
      'tcp': [
        {'type': 'fragment', 'settings': {'packets': '1-3', 'length': '6-14'}},
      ],
    };
    final b = parseLinks(v2rayLineLinks(_line({'network': 'tcp', 'security': 'none', 'finalmask': other}))).single;
    expect(a.key, isNot(b.key));
  });
}
