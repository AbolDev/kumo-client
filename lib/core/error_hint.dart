/// A short, plain reason for a connection that failed, from what the core said. The key of a text of
/// the app, or null when nothing fits (the caller then shows the first words of the core's own message).
String? errorHintKey(String? reason) {
  final r = (reason ?? '').toLowerCase();
  if (r.isEmpty || r == 'revoked') return null;
  bool has(List<String> words) => words.any(r.contains);
  if (has(['permission', 'not allowed', 'denied by the user'])) return 'errHintPermission';
  if (has(['certificate', 'x509', 'tls: ', 'handshake failure', 'bad record'])) return 'errHintTls';
  if (has(['no such host', 'lookup ', 'dns', 'resolve'])) return 'errHintDns';
  if (has(['refused'])) return 'errHintRefused';
  if (has(['timeout', 'timed out', 'deadline exceeded', 'i/o timeout'])) return 'errHintTimeout';
  if (has(['unreachable', 'no route', 'network is down', 'no network'])) return 'errHintNetwork';
  if (has(['unauthorized', 'authentication', 'auth failed', 'invalid user', 'wrong password', 'forbidden'])) {
    return 'errHintAuth';
  }
  if (has(['parse', 'decode', 'unknown field', 'invalid config', 'unsupported', 'json'])) return 'errHintConfig';
  return null;
}

/// The first line of [reason], cut to [max] characters, for when no plain text fits.
String shortReason(String? reason, {int max = 70}) {
  final line = (reason ?? '').trim().split(RegExp(r'[\r\n]+')).first.trim();
  return line.length <= max ? line : '${line.substring(0, max - 1)}…';
}
