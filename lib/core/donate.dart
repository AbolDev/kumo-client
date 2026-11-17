// The wallets people can send a donation to. They are written in the app (so they are there with no network and cannot be
// swapped by anyone who cannot change the app) and in the README. Because a wallet may change, the app also asks GitHub for
// docs/donate/wallets.json when the page is opened, and takes that list only when its signature fits (the same key and
// the same signing as the list of addresses of the usage count, see tools/donate_sign.dart) and every address in it has the
// shape of its network. A list that is not signed, does not check, or is not newer than the one in use is never taken.

import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'usage/usage_endpoints.dart' show usagePublicKeys;
import 'warp/warp_signature.dart';

/// The kinds of address the app knows the shape of. A wallet of another kind in a downloaded list is left out.
enum WalletKind { ton, tron, evm, btc, ltc }

class Wallet {
  const Wallet(this.kind, this.coin, this.network, this.address);

  final WalletKind kind;

  /// What is sent, as shown (`USDT`, `TON`).
  final String coin;

  /// The network it is sent on (`TRON`, `BNB Smart Chain`): an address of one network lost on another is gone.
  final String network;
  final String address;

  @override
  bool operator ==(Object other) => other is Wallet && other.kind == kind && other.address == address && other.coin == coin;

  @override
  int get hashCode => Object.hash(kind, address, coin);
}

/// What an address of each kind looks like (ASCII only, so nothing can pass for another letter).
final _shape = <WalletKind, RegExp>{
  WalletKind.ton: RegExp(r'^(?:UQ|EQ)[A-Za-z0-9_-]{46}$'),
  WalletKind.tron: RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{33}$'),
  WalletKind.evm: RegExp(r'^0x[0-9a-fA-F]{40}$'),
  WalletKind.btc: RegExp(r'^bc1[ac-hj-np-z02-9]{25,87}$'),
  WalletKind.ltc: RegExp(r'^ltc1[ac-hj-np-z02-9]{25,87}$'),
};

bool walletAddressFits(WalletKind kind, String address) => _shape[kind]!.hasMatch(address);

/// The list the app has before anything is downloaded. Version 1.
const builtInWalletsVersion = 1;
const builtInWallets = <Wallet>[
  Wallet(WalletKind.ton, 'TON', 'TON', 'UQApm3onic1pHi7PkvnUx-L_y9vycVJQUHrSXY4T8ksAzGwj'),
  Wallet(WalletKind.tron, 'TRX', 'TRON', 'TN3od12nkirPW6iN2y2RtrD6ERXb1Sws8S'),
  Wallet(WalletKind.evm, 'USDT', 'BNB Smart Chain (BEP-20)', '0x89af99EfAA7D4385aA087705606CDEfb9f532639'),
  Wallet(WalletKind.btc, 'BTC', 'Bitcoin', 'bc1qxgrf78l7t8j9e9lhtm444wyjmeu3d56kp6fdky'),
  Wallet(WalletKind.ltc, 'LTC', 'Litecoin', 'ltc1q55y0m367a4av678878l6dzzhf32kpu8vtvyr82'),
];

/// Where the list is downloaded from, one after the other (the same places as the WARP profile).
const donateListUrls = [
  'https://raw.githubusercontent.com/AbolDev/kumo-client/main/docs/donate/wallets.json',
  'https://cdn.jsdelivr.net/gh/AbolDev/kumo-client@main/docs/donate/wallets.json',
];

const donateSchema = 1;

class DonateFormatException implements Exception {
  DonateFormatException(this.message);
  final String message;

  @override
  String toString() => 'donate list: $message';
}

Never _fail(String what) => throw DonateFormatException(what);

class WalletList {
  const WalletList(this.version, this.wallets);

  final int version;
  final List<Wallet> wallets;
}

/// Reads and checks the text of a list. Throws [DonateFormatException].
WalletList parseWalletList(String text) {
  if (text.length > 16 * 1024) _fail('the file is too large');
  final Object? raw;
  try {
    raw = jsonDecode(text);
  } catch (_) {
    _fail('not JSON');
  }
  if (raw is! Map<String, dynamic>) _fail('not an object');
  final schema = raw['schema'];
  if (schema is! int || schema < 1) _fail('no layout number');
  if (schema > donateSchema) _fail('layout $schema is newer than this version understands');
  final version = raw['version'];
  if (version is! int || version < 1 || version > (1 << 30)) _fail('version is not valid');
  final keyId = raw['key_id'];
  if (keyId is! String || !RegExp(r'^[a-z0-9]{1,16}$').hasMatch(keyId)) _fail('key_id is not valid');
  final list = raw['wallets'];
  if (list is! List || list.isEmpty || list.length > 12) _fail('wallets is not valid');
  final out = <Wallet>[];
  for (final w in list) {
    if (w is! Map<String, dynamic>) _fail('a wallet is not an object');
    final kind = WalletKind.values.where((k) => k.name == w['kind']).firstOrNull;
    // A kind this version does not know is left out (a newer list may have one).
    if (kind == null) continue;
    final coin = w['coin'], network = w['network'], address = w['address'];
    if (coin is! String || !RegExp(r'^[A-Za-z0-9 ().-]{1,24}$').hasMatch(coin)) _fail('a wallet has no valid coin');
    if (network is! String || !RegExp(r'^[A-Za-z0-9 ().-]{1,40}$').hasMatch(network)) _fail('a wallet has no valid network');
    if (address is! String || !walletAddressFits(kind, address)) _fail('an address is not one of its network');
    out.add(Wallet(kind, coin, network, address));
  }
  if (out.isEmpty) _fail('no wallet of a kind this version knows');
  return WalletList(version, out);
}

/// The text a list's signature is over: the file as it is. [parseWalletList] after the signature, so that nothing unsigned is read.
WalletList checkWalletList(String text, String signature, {Map<String, String> keys = usagePublicKeys,
    bool Function(List<int> data, String signature, String publicKey) verify = verifyWarpSignature}) {
  final Object? raw;
  try {
    raw = jsonDecode(text);
  } catch (_) {
    _fail('not JSON');
  }
  final keyId = raw is Map ? raw['key_id'] : null;
  final key = keyId is String ? keys[keyId] : null;
  if (key == null) _fail('signed with a key this version does not know');
  if (!verify(utf8.encode(text), signature.trim(), key)) _fail('the signature does not fit');
  return parseWalletList(text);
}

const _savedList = 'donate_wallets.json';
const _savedSignature = 'donate_wallets.json.sig';

/// The wallets in use: the built-in list, or a downloaded one that is signed, valid and newer, which is kept on the device so
/// that the next start has it with no network. Nothing here throws. The page listens to [wallets].
class WalletStore {
  WalletStore({this.keys = usagePublicKeys, this.verify = verifyWarpSignature});

  final Map<String, String> keys;
  final bool Function(List<int> data, String signature, String publicKey) verify;

  final wallets = ValueNotifier<List<Wallet>>(builtInWallets);
  int _version = builtInWalletsVersion;

  List<Wallet> get current => wallets.value;

  bool _take(WalletList list) {
    if (list.version <= _version) return false;
    _version = list.version;
    wallets.value = list.wallets;
    return true;
  }

  /// Takes the list kept by the last download, when it still checks and is newer than the built-in one.
  Future<void> load(Future<String?> Function(String name) read) async {
    try {
      final text = await read(_savedList), sig = await read(_savedSignature);
      if (text == null || sig == null) return;
      _take(checkWalletList(text, sig, keys: keys, verify: verify));
    } catch (_) {}
  }

  /// Downloads the list ([fetch] gives the text at an address, or throws) and takes it, and keeps it with [write], when it
  /// is signed, valid and newer than the one in use. True when a newer list was taken.
  Future<bool> update(Future<String> Function(String url) fetch, Future<void> Function(String name, String content) write) async {
    for (final url in donateListUrls) {
      try {
        final text = await fetch(url);
        final sig = (await fetch('$url.sig')).trim();
        final fresh = checkWalletList(text, sig, keys: keys, verify: verify);
        if (!_take(fresh)) return false;
        try {
          await write(_savedList, text);
          await write(_savedSignature, sig);
        } catch (_) {}
        return true;
      } catch (_) {
        // the next source
      }
    }
    return false;
  }
}

/// The wallets the app uses.
final walletStore = WalletStore();
