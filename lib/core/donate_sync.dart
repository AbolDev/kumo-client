import 'dart:convert';
import 'dart:io';

import 'donate.dart';
import 'rule_sets.dart' show fetchDirect;
import 'vpn_channel.dart';

/// The text at [url] by the network's own way; throws when there is none.
Future<String> _get(String url) async {
  final bytes = await fetchDirect(url);
  if (bytes == null) throw StateError('no answer');
  return utf8.decode(bytes);
}

Future<File> _file(String name) async => File('${await VpnChannel.dataDir()}${Platform.pathSeparator}$name');

/// At the start of the app: the list kept by the last download first (so the wallets are right with no network), then a new
/// download in the background. A list that is not signed, not valid or not newer is never taken (see [WalletStore]).
Future<void> startWallets() async {
  await walletStore.load((name) async {
    final f = await _file(name);
    return f.existsSync() ? f.readAsString() : null;
  });
  await refreshWallets();
}

/// Asks GitHub for the list now (the start of the app, and the page of donations when it is opened).
Future<bool> refreshWallets() => walletStore.update(_get, (name, content) async => (await _file(name)).writeAsString(content, flush: true));
