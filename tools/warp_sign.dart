// Signs docs/warp/profile.json: checks that the file is a valid profile, writes the signature next to
// it (docs/warp/profile.json.sig) and checks that the signature fits the public key in the app.
//
//   dart run tools/warp_sign.dart [--key path/to/warp-private.key] [docs/warp/profile.json]
import 'dart:convert';
import 'dart:io';

import 'package:kumo/core/warp/warp_keys.dart';
import 'package:kumo/core/warp/warp_profile.dart';
import 'package:kumo/core/warp/warp_signature.dart';

void main(List<String> args) {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  var keyPath = '$home${Platform.pathSeparator}.kumo-signing${Platform.pathSeparator}warp-private.key';
  var path = 'docs/warp/profile.json';
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
  final WarpProfile profile;
  try {
    profile = parseWarpProfile(utf8.decode(data));
  } on WarpFormatException catch (e) {
    stderr.writeln('Not signed: $e');
    exit(1);
  }
  final sig = signWarp(data, key.readAsStringSync());
  if (!warpPublicKeys.values.any((pub) => verifyWarpSignature(data, sig, pub))) {
    stderr.writeln('Not signed: the key does not fit any public key in warp_keys.dart.');
    exit(1);
  }
  File('$path.sig').writeAsStringSync(sig);
  stdout.writeln('Signed $path (version ${profile.version}, key ${profile.keyId}, '
      '${profile.methods.length} methods).');
}
