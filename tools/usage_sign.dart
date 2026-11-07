// Signs docs/telemetry/endpoints.json: checks that the file is a valid list, writes the signature next
// to it (docs/telemetry/endpoints.json.sig) and checks that the signature fits the public key in the app.
//
//   dart run tools/usage_sign.dart [--key path/to/usage-private.key] [docs/telemetry/endpoints.json]
import 'dart:convert';
import 'dart:io';

import 'package:kumo/core/usage/usage_endpoints.dart';
import 'package:kumo/core/warp/warp_signature.dart';

void main(List<String> args) {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  var keyPath = '$home${Platform.pathSeparator}.kumo-signing${Platform.pathSeparator}usage-private.key';
  var path = 'docs/telemetry/endpoints.json';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--key' && i + 1 < args.length) {
      keyPath = args[++i];
    } else {
      path = args[i];
    }
  }
  final key = File(keyPath);
  final file = File(path);
  if (!key.existsSync() || !file.existsSync()) {
    stderr.writeln('Missing ${key.existsSync() ? path : keyPath}');
    exit(1);
  }
  // The same bytes the app will check: the file exactly as it is.
  final data = file.readAsBytesSync();
  final UsageEndpoints list;
  try {
    list = parseUsageEndpoints(utf8.decode(data));
  } on UsageFormatException catch (e) {
    stderr.writeln('Not signed: $e');
    exit(1);
  }
  if (usagePublicKeys.isEmpty) {
    stderr.writeln('Not signed: put the public key in usagePublicKeys (usage_endpoints.dart) first.');
    exit(1);
  }
  final sig = signWarp(data, key.readAsStringSync());
  if (!usagePublicKeys.values.any((pub) => verifyWarpSignature(data, sig, pub))) {
    stderr.writeln('Not signed: the key does not fit any public key in usage_endpoints.dart.');
    exit(1);
  }
  File('$path.sig').writeAsStringSync(sig);
  stdout.writeln('Signed $path (version ${list.version}, key ${list.keyId}, '
      '${list.endpoints.length} endpoints).');
}
