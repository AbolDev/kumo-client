import 'dart:convert';

/// An OpenVPN client configuration (`.ovpn`), read and rewritten.
///
/// The text a user brings can hold anything OpenVPN understands, including lines that run programs
/// (`up`, `down`, `route-up`, `plugin` ...), open a control port (`management`), write files (`log`)
/// or load more configuration (`config`). Kumo never runs the text it was given: it reads the lines it
/// knows, checks them, and writes a configuration of its own ([OvpnProfile.config]) that holds only
/// those. Everything else is left out and reported, so a downloaded file cannot do more than connect.

/// The file cannot be used. [missingFiles] lists the files it names that were not given.
class OvpnException implements Exception {
  OvpnException(this.message, {this.missingFiles = const []});

  final String message;
  final List<String> missingFiles;

  @override
  String toString() => message;
}

class OvpnRemote {
  const OvpnRemote(this.host, this.port, this.proto);

  final String host;
  final int port;

  /// `udp`, `udp4`, `udp6`, `tcp-client`, `tcp4-client` or `tcp6-client`.
  final String proto;

  bool get tcp => proto.startsWith('tcp');

  @override
  bool operator ==(Object other) =>
      other is OvpnRemote && other.host == host && other.port == port && other.proto == proto;

  @override
  int get hashCode => Object.hash(host, port, proto);
}

class OvpnProfile {
  const OvpnProfile({
    required this.remotes,
    required this.config,
    required this.needsLogin,
    required this.needsKeyPassword,
    required this.username,
    required this.password,
    required this.blocked,
    required this.ignored,
  });

  final List<OvpnRemote> remotes;

  /// The configuration Kumo runs: the lines it understood, rewritten, with the certificates and keys
  /// inline. It holds no user name or password.
  final String config;

  /// The server asks for a user name and password (`auth-user-pass`).
  final bool needsLogin;

  /// The private key is encrypted: its passphrase is needed.
  final bool needsKeyPassword;

  /// A user name and password the file itself carried (`auth-user-pass file`), if any.
  final String? username;
  final String? password;

  /// Lines that could run something or reach outside the connection, which were not used.
  final List<String> blocked;

  /// Lines Kumo does not know, which were not used.
  final List<String> ignored;

  String get host => remotes.first.host;
}

/// Directives that are left out because they run programs, open control ports, read or write files, or
/// change how the process runs.
const _blocked = {
  'script-security', 'up', 'down', 'route-up', 'route-pre-down', 'up-restart', 'down-pre', 'up-delay',
  'ipchange', 'tls-verify', 'client-connect', 'client-disconnect', 'learn-address', 'auth-user-pass-verify',
  'plugin', 'management', 'management-client', 'management-query-passwords', 'management-hold',
  'management-signal', 'management-log-cache', 'management-up-down', 'management-client-user',
  'management-client-group', 'management-forget-disconnect', 'management-external-key',
  'management-external-cert', 'management-query-proxy', 'management-query-remote', 'config', 'daemon',
  'log', 'log-append', 'syslog', 'writepid', 'cd', 'chroot', 'user', 'group', 'setcon', 'echo', 'engine',
  'lladdr', 'ifconfig-noexec', 'route-noexec', 'dev-node', 'windows-driver', 'win-sys', 'msg-channel',
  'service', 'setenv', 'setenv-safe', 'tmp-dir', 'status', 'status-version', 'show-ciphers', 'show-digests',
  'show-tls', 'show-engines', 'show-curves', 'show-groups', 'genkey', 'mktun', 'rmtun', 'providers',
  'machine-readable-output', 'inetd', 'use-prediction-resistance', 'bcast-buffers', 'priority', 'nice',
  'mlock',
};

/// Directives that are known and have no use here, or are decided by Kumo: left out without a word.
const _quiet = {
  'client', 'pull', 'tls-client', 'dev-type', 'persist-key', 'persist-tun', 'persist-local-ip',
  'persist-remote-ip', 'nobind', 'verb', 'mute', 'suppress-timestamps', 'passtos', 'client-cert-not-required',
  'explicit-exit-notify', 'auth-retry', 'ping-timer-rem', 'resolv-retry', 'float',
  'redirect-gateway', 'redirect-private', 'route', 'route-ipv6', 'route-nopull', 'route-gateway',
  'route-delay', 'route-method', 'pull-filter', 'push-peer-info', 'dhcp-option', 'dhcp-renew',
  'dhcp-release', 'block-outside-dns', 'register-dns', 'ip-win32', 'tap-sleep', 'rdns-internal',
  'topology', 'ifconfig', 'ifconfig-ipv6', 'ifconfig-nowarn', 'ifconfig-pool', 'tun-ipv6', 'ip-remote-hint',
  'lport', 'local', 'bind', 'remote-random-hostname', 'allow-pull-fqdn', 'dh', 'comp-noadapt',
  'ignore-unknown-option', 'disable-dco', 'disable-occ', 'opt-verify',
  'txqueuelen', 'socket-flags', 'mark', 'tcp-queue-limit', 'fast-io', 'ncp-disable', 'key-method',
  'mute-replay-warnings', 'replay-persist', 'no-replay', 'askpass', 'show-net',
  'show-net-up', 'dev', 'proto', 'port', 'rport', 'connect-retry', 'connect-retry-max', 'remote-random',
  'pkcs11-providers', 'pkcs11-id', 'pkcs11-id-management', 'pkcs11-private-mode', 'pkcs11-protected-authentication',
  'cryptoapicert', 'capath',
};

/// Directives copied as they are (name -> how many values at most), after the values are checked.
const _copied = <String, int>{
  'remote-random': 0,
  'connect-retry': 2,
  'connect-retry-max': 1,
  'connect-timeout': 1,
  'server-poll-timeout': 1,
  'resolv-retry': 1,
  'float': 0,
  'remote-cert-tls': 1,
  'remote-cert-ku': 8,
  'remote-cert-eku': 1,
  'ns-cert-type': 1,
  'verify-x509-name': 2,
  'peer-fingerprint': 8,
  'verify-hash': 2,
  'tls-cipher': 1,
  'tls-ciphersuites': 1,
  'tls-version-min': 2,
  'tls-version-max': 1,
  'tls-groups': 1,
  'tls-cert-profile': 1,
  'cipher': 1,
  'data-ciphers': 1,
  'data-ciphers-fallback': 1,
  'ncp-ciphers': 1,
  'auth': 1,
  'keysize': 1,
  'auth-nocache': 0,
  'reneg-sec': 1,
  'reneg-bytes': 1,
  'reneg-pkts': 1,
  'replay-window': 2,
  'comp-lzo': 1,
  'compress': 1,
  'allow-compression': 1,
  'keepalive': 2,
  'ping': 1,
  'ping-restart': 1,
  'ping-exit': 1,
  'inactive': 2,
  'tun-mtu': 1,
  'link-mtu': 1,
  'mssfix': 2,
  'fragment': 1,
  'sndbuf': 1,
  'rcvbuf': 1,
  'explicit-exit-notify': 1,
  'hand-window': 1,
  'tran-window': 1,
  'tls-timeout': 1,
  'socks-proxy': 2,
  'x509-username-field': 1,
};

const _protos = {'udp', 'udp4', 'udp6', 'tcp', 'tcp4', 'tcp6', 'tcp-client', 'tcp4-client', 'tcp6-client'};

String _proto(String p) => switch (p) {
      'tcp' => 'tcp-client',
      'tcp4' => 'tcp4-client',
      'tcp6' => 'tcp6-client',
      _ => p,
    };

/// A word as OpenVPN reads it: separated by white space, with "double" or 'single' quotes and the
/// backslash. Null when a quote is not closed.
List<String>? _words(String line) {
  final out = <String>[];
  final b = StringBuffer();
  var inWord = false;
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' && quote == '"' && i + 1 < line.length) {
        b.write(line[++i]);
      } else {
        b.write(c);
      }
    } else if (c == '"' || c == "'") {
      quote = c;
      inWord = true;
    } else if (c == r'\' && i + 1 < line.length) {
      b.write(line[++i]);
      inWord = true;
    } else if (c == ' ' || c == '\t') {
      if (inWord) {
        out.add(b.toString());
        b.clear();
        inWord = false;
      }
    } else {
      b.write(c);
      inWord = true;
    }
  }
  if (quote != null) return null;
  if (inWord) out.add(b.toString());
  return out;
}

/// A word written back so that OpenVPN reads the same word. Null when it holds a control character.
String? _write(String w) {
  if (w.isEmpty || w.runes.any((r) => r < 0x20 || r == 0x7f)) return null;
  if (RegExp(r'^[A-Za-z0-9._:/@+=,%\-\[\]]+$').hasMatch(w)) return w;
  return '"${w.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

final _host = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9._\-]*[A-Za-z0-9])?$|^[0-9A-Fa-f:.]+$');
final _value = RegExp(r'^[A-Za-z0-9:_\-+@=,./\[\]]+$');

/// The names that may hold other printable characters (a certificate name has spaces).
const _loose = {'verify-x509-name', 'x509-username-field'};
final _printable = RegExp(r'^[\x20-\x7e]{1,128}$');

/// What the blocks and the files of each option must look like.
const _pem = <String, List<String>>{
  'ca': ['CERTIFICATE'],
  'cert': ['CERTIFICATE'],
  'extra-certs': ['CERTIFICATE'],
  'key': ['PRIVATE KEY', 'RSA PRIVATE KEY', 'EC PRIVATE KEY', 'ENCRYPTED PRIVATE KEY'],
  'tls-auth': ['OpenVPN Static key V1'],
  'tls-crypt': ['OpenVPN Static key V1'],
  'tls-crypt-v2': ['OpenVPN tls-crypt-v2 client key'],
  'crl-verify': ['X509 CRL'],
};

const _blockTags = {..._pem, 'pkcs12': <String>[], 'connection': <String>[]};

const _maxBlock = 64 * 1024;
const _maxTotal = 256 * 1024;

/// Reads [text]. [files] holds the files that go with it (the certificate files of the folder the
/// `.ovpn` was in), by file name, for the lines that name a file instead of holding it.
OvpnProfile parseOvpn(String text, {Map<String, String> files = const {}}) {
  if (text.length > _maxTotal) throw OvpnException('The file is too large to be an OpenVPN configuration.');
  final lines = text.replaceAll('﻿', '').split(RegExp(r'\r\n|\r|\n'));

  final blocks = <String, String>{};
  final connections = <List<String>>[];
  final directives = <List<String>>[];
  final blocked = <String>[];
  final ignored = <String>[];
  final missing = <String>[];

  // Split the text into inline blocks and the lines of directives.
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i].trim();
    if (raw.isEmpty || raw.startsWith('#') || raw.startsWith(';')) continue;
    final open = RegExp(r'^<([A-Za-z0-9\-]+)>$').firstMatch(raw);
    if (open != null) {
      final tag = open[1]!;
      final body = <String>[];
      var closed = false;
      for (i++; i < lines.length; i++) {
        if (lines[i].trim() == '</$tag>') {
          closed = true;
          break;
        }
        body.add(lines[i]);
      }
      if (!closed) throw OvpnException('The block <$tag> is not closed.');
      if (tag == 'connection') {
        connections.add(body);
      } else if (_blockTags.containsKey(tag)) {
        final content = body.map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
        if (content.length > _maxBlock) throw OvpnException('The block <$tag> is too large.');
        blocks[tag] = content;
      } else if (_blocked.contains(tag)) {
        blocked.add('<$tag>');
      } else {
        ignored.add('<$tag>');
      }
      continue;
    }
    final words = _words(raw);
    if (words == null || words.isEmpty) {
      throw OvpnException('Line ${i + 1} has a quote that is not closed.');
    }
    directives.add(words);
  }

  // The remotes: `remote host [port [proto]]`, from the top and from <connection> blocks. The
  // `proto` and `port` of a scope (the top, or one block) apply to the remotes of that scope, in
  // whichever order the lines come.
  String? topProto;
  int? topPort;
  final raw = <({String host, int? port, String? proto, int scope})>[];
  final scopeProto = <int, String>{};
  final scopePort = <int, int>{};
  var scope = -1;
  final out = <List<String>>[];
  final inline = <String, String>{};
  var needsLogin = false;
  String? user, pass;
  var client = false;
  var staticKey = false;
  String? keyDirection;

  String fileText(String name) {
    final base = name.replaceAll('\\', '/').split('/').last;
    final hit = files[name] ?? files[base];
    if (hit == null) {
      missing.add(base);
      return '';
    }
    return hit;
  }

  void handle(List<String> w) {
    final name = w.first.toLowerCase();
    final args = w.sublist(1);
    switch (name) {
      case 'client' || 'pull' || 'tls-client':
        client = true;
      case 'dev':
        final dev = args.isEmpty ? '' : args.first;
        if (dev.startsWith('tap')) {
          throw OvpnException('This configuration uses a TAP (bridged) device, which Kumo does not support.');
        }
      case 'proto':
        if (args.isEmpty || !_protos.contains(args.first.toLowerCase())) {
          if (args.isNotEmpty && args.first.toLowerCase() == 'tcp-server') {
            throw OvpnException('A configuration that waits for connections (tcp-server) cannot be used.');
          }
          throw OvpnException('The protocol "${args.isEmpty ? '' : args.first}" is not one OpenVPN knows.');
        }
        if (scope < 0) {
          topProto = _proto(args.first.toLowerCase());
        } else {
          scopeProto[scope] = _proto(args.first.toLowerCase());
        }
      case 'port' || 'rport':
        final p = args.isEmpty ? null : int.tryParse(args.first);
        if (p == null || p < 1 || p > 65535) throw OvpnException('The port "${args.isEmpty ? '' : args.first}" is not valid.');
        if (scope < 0) {
          topPort = p;
        } else {
          scopePort[scope] = p;
        }
      case 'remote':
        if (args.isEmpty || args.length > 3) throw OvpnException('A "remote" line needs a host, a port and a protocol at most.');
        final host = args[0];
        if (host.length > 253 || !_host.hasMatch(host)) throw OvpnException('The host "$host" is not valid.');
        final port = args.length > 1 ? int.tryParse(args[1]) : null;
        if (args.length > 1 && (port == null || port < 1 || port > 65535)) {
          throw OvpnException('The port of $host is not valid.');
        }
        final proto = args.length > 2 ? args[2].toLowerCase() : null;
        if (proto != null && !_protos.contains(proto)) throw OvpnException('The protocol of $host is not valid.');
        raw.add((host: host, port: port, proto: proto == null ? null : _proto(proto), scope: scope));
      case 'auth-user-pass':
        needsLogin = true;
        if (args.isNotEmpty) {
          final given = files[args.first] ?? files[args.first.replaceAll('\\', '/').split('/').last] ?? '';
          final lines = given.split(RegExp(r'\r?\n'));
          if (lines.length >= 2 && lines[0].isNotEmpty) {
            user = lines[0];
            pass = lines[1];
          }
        }
      case 'key-direction':
        if (args.length == 1 && (args.first == '0' || args.first == '1')) keyDirection = args.first;
      case 'secret':
        staticKey = true;
      case 'ca' || 'cert' || 'key' || 'extra-certs' || 'tls-auth' || 'tls-crypt' || 'tls-crypt-v2' || 'crl-verify' || 'pkcs12':
        if (args.isEmpty) throw OvpnException('The line "$name" names no file.');
        if (name == 'tls-auth' && args.length > 1 && (args[1] == '0' || args[1] == '1')) keyDirection = args[1];
        if (!blocks.containsKey(name)) inline[name] = fileText(args.first);
      case 'http-proxy':
        if (args.length < 2) throw OvpnException('An "http-proxy" line needs a host and a port.');
        final p = int.tryParse(args[1]);
        if (!_host.hasMatch(args[0]) || p == null || p < 1 || p > 65535) {
          throw OvpnException('The http-proxy line is not valid.');
        }
        // The proxy's own login file (and the "auto" modes) are not used.
        out.add(['http-proxy', args[0], args[1]]);
      case _:
        if (_blocked.contains(name)) {
          blocked.add(name);
        } else if (_copied.containsKey(name)) {
          if (args.length > _copied[name]!) {
            ignored.add(name);
            return;
          }
          if (args.any((a) => !(_loose.contains(name) ? _printable : _value).hasMatch(a))) {
            ignored.add(name);
            return;
          }
          out.add([name, ...args]);
        } else if (!_quiet.contains(name)) {
          ignored.add(name);
        }
    }
  }

  for (final d in directives) {
    handle(d);
  }
  for (var i = 0; i < connections.length; i++) {
    scope = i;
    for (final rawLine in connections[i]) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
      final w = _words(line);
      if (w == null || w.isEmpty) continue;
      final n = w.first.toLowerCase();
      // Only what picks a server is read from a connection block.
      if (n == 'remote' || n == 'proto' || n == 'port' || n == 'rport') handle(w);
    }
  }
  final remotes = [
    for (final r in raw)
      OvpnRemote(
        r.host,
        r.port ?? (r.scope >= 0 ? scopePort[r.scope] : null) ?? topPort ?? 1194,
        r.proto ?? (r.scope >= 0 ? scopeProto[r.scope] : null) ?? topProto ?? 'udp',
      ),
  ];

  if (staticKey) throw OvpnException('A configuration with a shared static key (secret) is not supported.');
  if (missing.isNotEmpty) {
    final names = missing.toSet().toList();
    throw OvpnException('The configuration names files that were not given: ${names.join(', ')}.', missingFiles: names);
  }
  if (remotes.isEmpty) throw OvpnException('The configuration has no "remote" line (no server).');
  if (!client) throw OvpnException('This is not a client configuration (it has no "client" line).');

  // The certificates and keys, from the blocks or from the files.
  final material = <String, String>{...inline, ...blocks};
  material.remove('connection');
  var needsKeyPassword = false;
  for (final e in material.entries) {
    final allowed = _pem[e.key];
    if (e.key == 'pkcs12') {
      final b64 = e.value.replaceAll(RegExp(r'\s'), '');
      if (b64.isEmpty || !RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(b64)) throw OvpnException('The <pkcs12> block is not valid.');
      continue;
    }
    if (allowed == null) continue;
    final body = e.value;
    final begin = RegExp(r'-----BEGIN ([^-]+)-----').firstMatch(body);
    if (begin == null || !allowed.contains(begin[1]) || !body.contains('-----END ${begin[1]}-----')) {
      throw OvpnException('The ${e.key} is not what OpenVPN expects (${allowed.first}).');
    }
    if (e.key == 'key' && (begin[1] == 'ENCRYPTED PRIVATE KEY' || body.contains('Proc-Type: 4,ENCRYPTED'))) {
      needsKeyPassword = true;
    }
  }
  if (!material.containsKey('ca') && !out.any((l) => l[0] == 'peer-fingerprint' || l[0] == 'verify-hash')) {
    throw OvpnException('The configuration has no certificate authority (ca) to check the server with.');
  }
  final hasCert = (material.containsKey('cert') && material.containsKey('key')) || material.containsKey('pkcs12');
  if (!hasCert && !needsLogin) {
    throw OvpnException('The configuration has neither a client certificate nor a user name and password.');
  }

  // The configuration that is run: only what was read and checked.
  final b = StringBuffer('client\ndev tun\n');
  for (final r in remotes) {
    final host = _write(r.host);
    if (host == null) throw OvpnException('The host "${r.host}" is not valid.');
    b.writeln('remote $host ${r.port} ${r.proto}');
  }
  if (remotes.length > 1 && !out.any((l) => l[0] == 'remote-random')) {
    // The order of the file is kept; the user can add remote-random in the file.
  }
  for (final l in out) {
    final words = <String>[];
    for (final w in l) {
      final written = _write(w);
      if (written == null) throw OvpnException('The line "${l.first}" holds a character that is not allowed.');
      words.add(written);
    }
    b.writeln(words.join(' '));
  }
  if (needsLogin) b.writeln('auth-user-pass');
  if (keyDirection != null && (material.containsKey('tls-auth'))) b.writeln('key-direction $keyDirection');
  b.writeln('nobind\npersist-key\nverb 3');
  const order = ['ca', 'cert', 'key', 'extra-certs', 'tls-auth', 'tls-crypt', 'tls-crypt-v2', 'crl-verify', 'pkcs12'];
  var total = 0;
  for (final tag in order) {
    final v = material[tag];
    if (v == null || v.isEmpty) continue;
    total += v.length;
    b.writeln('<$tag>\n$v\n</$tag>');
  }
  if (total > _maxTotal) throw OvpnException('The certificates and keys are too large.');

  return OvpnProfile(
    remotes: List.unmodifiable(remotes),
    config: b.toString(),
    needsLogin: needsLogin,
    needsKeyPassword: needsKeyPassword,
    username: user,
    password: pass,
    blocked: blocked.toSet().toList(),
    ignored: ignored.toSet().toList(),
  );
}

/// True when [text] looks like an OpenVPN client configuration (before it is read in full).
bool looksLikeOvpn(String text) {
  if (text.length > _maxTotal) return false;
  return RegExp(r'^\s*remote\s+\S+', multiLine: true).hasMatch(text) &&
      RegExp(r'^\s*(client|tls-client|pull)\s*$', multiLine: true).hasMatch(text) &&
      !text.contains('[Interface]');
}

/// The `openvpn://` link of a configuration: the sanitized text (base64) and, when the user gave one,
/// the login. The name follows the `#`.
String ovpnLink(OvpnProfile p, {String? username, String? password, String? keyPassword, String? name}) {
  final b64 = base64Url.encode(utf8.encode(p.config)).replaceAll('=', '');
  final query = [
    if ((username ?? p.username) != null) 'user=${Uri.encodeQueryComponent((username ?? p.username)!)}',
    if ((password ?? p.password) != null) 'pass=${Uri.encodeQueryComponent((password ?? p.password)!)}',
    if (keyPassword != null) 'kpass=${Uri.encodeQueryComponent(keyPassword)}',
  ].join('&');
  return 'openvpn://$b64${query.isEmpty ? '' : '?$query'}#${Uri.encodeComponent(name ?? p.host)}';
}

/// The link of an OpenVPN configuration in [text], or none when it is not one or cannot be used (a
/// reason is given by [parseOvpn], which the screens call themselves to tell the user).
List<String> ovpnToLinks(String text, {Map<String, String> files = const {}, String? name}) {
  if (!looksLikeOvpn(text)) return const [];
  try {
    return [ovpnLink(parseOvpn(text, files: files), name: name)];
  } on OvpnException {
    return const [];
  }
}
