import 'dart:convert';

/// A share link taken apart into fields a form can edit, and put back together.
class LinkFields {
  LinkFields._(
      this.scheme, this.name, this.host, this.port, this.secret, this.params);

  final String scheme;
  String name;
  String host;
  String port;

  /// UUID (vless, vmess, tuic uuid:password), password (trojan, hysteria2, ss).
  String secret;

  /// Everything else (security, sni, path, ...), in the order of the link.
  final Map<String, String> params;

  bool get isVmess => scheme == 'vmess';

  static LinkFields? parse(String link) {
    final scheme = link.split('://').first.toLowerCase();
    try {
      if (scheme == 'vmess') return _vmess(link);
      if (scheme == 'ss') return _ss(link);
      return _uri(scheme == 'hy2' ? 'hysteria2' : scheme, link);
    } catch (_) {
      return null;
    }
  }

  static LinkFields _vmess(String link) {
    final body = link.substring('vmess://'.length).trim();
    final j = jsonDecode(utf8.decode(base64.decode(base64.normalize(body))))
        as Map<String, dynamic>;
    final params = <String, String>{};
    j.forEach((k, v) {
      if (const {'ps', 'add', 'port', 'id', 'v'}.contains(k)) return;
      params[k] = '${v ?? ''}';
    });
    return LinkFields._('vmess', '${j['ps'] ?? ''}', '${j['add'] ?? ''}',
        '${j['port'] ?? ''}', '${j['id'] ?? ''}', params);
  }

  static LinkFields _ss(String link) {
    var rest = link.substring('ss://'.length);
    var name = '';
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      name = Uri.decodeComponent(rest.substring(hash + 1));
      rest = rest.substring(0, hash);
    }
    final query = rest.indexOf('?');
    final params = <String, String>{};
    if (query >= 0) {
      params.addAll(Uri.splitQueryString(rest.substring(query + 1)));
      rest = rest.substring(0, query);
    }
    String userInfo, hostPort;
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      userInfo = rest.substring(0, at);
      hostPort = rest.substring(at + 1);
    } else {
      final plain = utf8.decode(base64.decode(base64.normalize(rest)));
      final i = plain.lastIndexOf('@');
      userInfo = plain.substring(0, i);
      hostPort = plain.substring(i + 1);
    }
    if (!userInfo.contains(':')) {
      userInfo = utf8.decode(base64.decode(base64.normalize(userInfo)));
    } else {
      userInfo = Uri.decodeComponent(userInfo);
    }
    final c = userInfo.indexOf(':');
    final colon = hostPort.lastIndexOf(':');
    return LinkFields._(
      'ss',
      name,
      hostPort.substring(0, colon).replaceAll(RegExp(r'^\[|\]$'), ''),
      hostPort.substring(colon + 1),
      userInfo.substring(c + 1),
      {'method': userInfo.substring(0, c), ...params},
    );
  }

  static LinkFields _uri(String scheme, String link) {
    var text = link.replaceFirst(RegExp('^hy2://'), 'hysteria2://');
    // `host:443,5000-6000` (port hopping) is not a valid URI: the extra ports move to `mport`.
    final hop = RegExp(r'(@[^/?#@]+:\d+),([\d,\-]+)').firstMatch(text);
    if (hop != null) text = text.replaceFirst(hop.group(0)!, hop.group(1)!);
    final u = Uri.parse(text);
    final params = Map.of(u.queryParameters);
    if (hop != null && (params['mport'] ?? '').isEmpty) {
      params['mport'] = hop.group(2)!;
    }
    return LinkFields._(
      scheme,
      Uri.decodeComponent(u.fragment),
      u.host,
      u.hasPort ? '${u.port}' : '',
      u.userInfo.contains('%') ? Uri.decodeComponent(u.userInfo) : u.userInfo,
      params,
    );
  }

  /// The link for the current values.
  String build() {
    final h = host.contains(':') ? '[$host]' : host;
    final params = Map.of(this.params)..removeWhere((k, v) => v.isEmpty);
    if (scheme == 'vmess') {
      final j = <String, dynamic>{
        'v': '2',
        'ps': name,
        'add': host,
        'port': port,
        'id': secret,
        ...params,
      };
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
    }
    final fragment = name.isEmpty ? '' : '#${Uri.encodeComponent(name)}';
    if (scheme == 'ss') {
      final method = params.remove('method') ?? 'aes-256-gcm';
      final user =
          base64Url.encode(utf8.encode('$method:$secret')).replaceAll('=', '');
      final query =
          params.isEmpty ? '' : '?${Uri(queryParameters: params).query}';
      return 'ss://$user@$h:$port$query$fragment';
    }
    final user = secret.isEmpty
        ? ''
        : '${Uri.encodeComponent(secret).replaceAll('%3A', ':')}@';
    final query =
        params.isEmpty ? '' : '?${Uri(queryParameters: params).query}';
    return '$scheme://$user$h:$port$query$fragment';
  }
}
