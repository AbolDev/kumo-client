// Makes the key pair that signs docs/warp/profile.json. The private key goes to a file OUTSIDE the
// repository (default: ~/.kumo-signing/warp-private.key) and is never printed; the public key is
// printed, to be put in lib/core/warp/warp_keys.dart.
//
//   dart run tools/warp_keygen.dart [directory]
import 'dart:io';

import 'package:kumo/core/warp/warp_signature.dart';

void main(List<String> args) {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  final dir = Directory(args.isNotEmpty ? args[0] : '$home${Platform.pathSeparator}.kumo-signing');
  final file = File('${dir.path}${Platform.pathSeparator}warp-private.key');
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
