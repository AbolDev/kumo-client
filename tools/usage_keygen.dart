// Makes the key pair that signs docs/telemetry/endpoints.json (the list of addresses the usage ping
// goes to). It is NOT the WARP key. The private key goes to a file OUTSIDE the repository (default:
// ~/.kumo-signing/usage-private.key) and is never printed; the public key is printed, to be put in
// lib/core/usage/usage_endpoints.dart as `usagePublicKeys = {'t1': '<public key>'}`.
//
//   dart run tools/usage_keygen.dart [directory]
import 'dart:io';

import 'package:kumo/core/warp/warp_signature.dart';

void main(List<String> args) {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  final dir = Directory(args.isNotEmpty ? args[0] : '$home${Platform.pathSeparator}.kumo-signing');
  final file = File('${dir.path}${Platform.pathSeparator}usage-private.key');
  if (file.existsSync()) {
    stderr.writeln('${file.path} exists already; not overwritten.');
    exit(1);
  }
  dir.createSync(recursive: true);
  final (priv, pub) = newWarpKeyPair();
  file.writeAsStringSync(priv);
  stdout.writeln('Private key written to ${file.path} (keep it, and keep it to yourself).');
  stdout.writeln('Public key: $pub');
}
