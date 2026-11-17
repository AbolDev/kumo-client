// Signs docs/donate/wallets.json: checks that the file is a valid list of wallets, writes the signature next to it
// (docs/donate/wallets.json.sig) and checks that the signature fits the public key in the app. The key is the one of the
// usage count (`dart run tools/usage_keygen.dart` made it).
//
//   dart run tools/donate_sign.dart [--key path/to/usage-private.key] [docs/donate/wallets.json]
//
// When a wallet changes: change it in docs/donate/wallets.json (and in the READMEs, and in builtInWallets of
// lib/core/donate.dart), raise "version", sign again, commit the file and its .sig.
import 'dart:convert';
import 'dart:io';

import 'package:kumo/core/donate.dart';
import 'package:kumo/core/usage/usage_endpoints.dart' show usagePublicKeys;
import 'package:kumo/core/warp/warp_signature.dart';

void main(List<String> args) {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  var keyPath = '$home${Platform.pathSeparator}.kumo-signing${Platform.pathSeparator}usage-private.key';
  var path = 'docs/donate/wallets.json';
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
  final WalletList list;
  try {
    list = parseWalletList(utf8.decode(data));
  } on DonateFormatException catch (e) {
    stderr.writeln('Not signed: $e');
    exit(1);
  }
  final sig = signWarp(data, key.readAsStringSync());
  if (!usagePublicKeys.values.any((pub) => verifyWarpSignature(data, sig, pub))) {
    stderr.writeln('Not signed: the key does not fit any public key in usage_endpoints.dart.');
    exit(1);
  }
  File('$path.sig').writeAsStringSync(sig);
  stdout.writeln('Signed $path (version ${list.version}, ${list.wallets.length} wallets).');
}
