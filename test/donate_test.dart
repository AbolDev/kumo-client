import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/donate.dart';
import 'package:kumo/screens/donate_page.dart';
import 'package:pointycastle/digests/keccak.dart';
import 'package:pointycastle/digests/sha256.dart';

// The checks below are the ones a wallet does itself: if an address was mistyped when it was copied here, one of them fails.

const _bech32 = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

int _polymod(List<int> values) {
  const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final v in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if (((top >> i) & 1) != 0) chk ^= gen[i];
    }
  }
  return chk;
}

/// A segwit address (BIP-173): the checksum fits (the constant 1 is the one of version 0).
bool _bech32Fits(String address, String hrp) {
  final sep = address.lastIndexOf('1');
  if (address.substring(0, sep) != hrp) return false;
  final data = [for (final c in address.substring(sep + 1).split('')) _bech32.indexOf(c)];
  if (data.contains(-1)) return false;
  final expand = [...hrp.codeUnits.map((c) => c >> 5), 0, ...hrp.codeUnits.map((c) => c & 31)];
  return _polymod([...expand, ...data]) == 1;
}

Uint8List _sha256(List<int> data) => SHA256Digest().process(Uint8List.fromList(data));

const _b58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/// A Tron address: base58 of 25 bytes whose last four are the start of the double SHA-256 of the first 21 (the first is 0x41).
bool _tronFits(String address) {
  var n = BigInt.zero;
  for (final c in address.split('')) {
    final i = _b58.indexOf(c);
    if (i < 0) return false;
    n = n * BigInt.from(58) + BigInt.from(i);
  }
  final bytes = <int>[];
  while (n > BigInt.zero) {
    bytes.insert(0, (n & BigInt.from(255)).toInt());
    n >>= 8;
  }
  if (bytes.length != 25 || bytes.first != 0x41) return false;
  final sum = _sha256(_sha256(bytes.sublist(0, 21))).sublist(0, 4);
  for (var i = 0; i < 4; i++) {
    if (sum[i] != bytes[21 + i]) return false;
  }
  return true;
}

/// A TON address in its friendly form: a tag, the workchain, 32 bytes, and the CRC-16 (XMODEM) of those 34 bytes.
bool _tonFits(String address) {
  final bytes = base64.decode(base64.normalize(address.replaceAll('-', '+').replaceAll('_', '/')));
  if (bytes.length != 36) return false;
  var crc = 0;
  for (final b in bytes.sublist(0, 34)) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return bytes[34] == (crc >> 8) && bytes[35] == (crc & 0xFF);
}

/// An Ethereum-style address with its capitals (EIP-55): the capitals say which letters the Keccak hash of the lower-case address
/// marks.
bool _evmFits(String address) {
  final hex = address.substring(2);
  final lower = hex.toLowerCase();
  final hash = KeccakDigest(256).process(Uint8List.fromList(lower.codeUnits));
  for (var i = 0; i < lower.length; i++) {
    final c = lower[i];
    if (!RegExp('[a-f]').hasMatch(c)) continue;
    final nibble = (hash[i ~/ 2] >> (i.isEven ? 4 : 0)) & 0xF;
    if ((nibble >= 8 ? c.toUpperCase() : c) != hex[i]) return false;
  }
  return true;
}

void main() {
  Wallet w(WalletKind k) => builtInWallets.firstWhere((x) => x.kind == k);

  test('every address in the app is one of its network, with its checksum', () {
    for (final x in builtInWallets) {
      expect(walletAddressFits(x.kind, x.address), isTrue, reason: x.address);
    }
    expect(_tonFits(w(WalletKind.ton).address), isTrue, reason: 'TON');
    expect(_tronFits(w(WalletKind.tron).address), isTrue, reason: 'Tron');
    expect(_evmFits(w(WalletKind.evm).address), isTrue, reason: 'BNB Smart Chain (EIP-55)');
    expect(_bech32Fits(w(WalletKind.btc).address, 'bc'), isTrue, reason: 'Bitcoin');
    expect(_bech32Fits(w(WalletKind.ltc).address, 'ltc'), isTrue, reason: 'Litecoin');
  });

  test('the checks catch a letter that was changed', () {
    expect(_bech32Fits('${w(WalletKind.btc).address.substring(0, 20)}x${w(WalletKind.btc).address.substring(21)}', 'bc'), isFalse);
    expect(_tronFits('TN3od12nkirPW6iN2y2RtrD6ERXb1Sws8T'), isFalse);
  });

  test('the file on GitHub, the READMEs and the app say the same', () {
    final list = parseWalletList(File('docs/donate/wallets.json').readAsStringSync());
    expect(list.version, builtInWalletsVersion);
    expect(list.wallets, builtInWallets);
    for (final f in Directory('.').listSync().whereType<File>().where((f) => RegExp(r'README(\.[A-Za-z-]+)?\.md$').hasMatch(f.path))) {
      final text = f.readAsStringSync();
      for (final x in builtInWallets) {
        expect(text, contains(x.address), reason: '${f.path} lacks ${x.coin}');
      }
    }
  });

  String listText({int version = 2, String address = 'TN3od12nkirPW6iN2y2RtrD6ERXb1Sws8S', String kind = 'tron'}) => jsonEncode({
        'schema': 1,
        'version': version,
        'key_id': 't1',
        'wallets': [
          {'kind': kind, 'coin': 'TRX', 'network': 'TRON', 'address': address},
          {'kind': 'future-coin', 'coin': 'X', 'network': 'X', 'address': 'anything'},
        ],
      });

  test('a list is read only when every address has the shape of its network', () {
    expect(parseWalletList(listText()).wallets.single.address, 'TN3od12nkirPW6iN2y2RtrD6ERXb1Sws8S',
        reason: 'a kind this version does not know is left out');
    expect(() => parseWalletList(listText(address: 'TN3od12nkirPW6iN2y2RtrD6ERXb1Sws8')), throwsA(isA<DonateFormatException>()));
    expect(() => parseWalletList(listText(address: '0xTN3od12nkirPW6iN2y2RtrD6ERXb1Sws8S')), throwsA(isA<DonateFormatException>()));
    expect(() => parseWalletList('{"schema":2,"version":1,"key_id":"t1","wallets":[]}'), throwsA(isA<DonateFormatException>()));
    expect(() => parseWalletList('not json'), throwsA(isA<DonateFormatException>()));
  });

  test('a downloaded list is taken only when it is signed and newer, and is kept for the next start', () async {
    Future<String> fetch(String url) async => url.endsWith('.sig') ? 'signature' : listText();
    bool yes(List<int> d, String s, String k) => true;
    bool no(List<int> d, String s, String k) => false;
    final saved = <String, String>{};
    Future<void> write(String name, String content) async => saved[name] = content;

    final store = WalletStore(verify: yes);
    expect(store.current, builtInWallets);
    expect(await store.update(fetch, write), isTrue);
    expect(store.current.single.address, 'TN3od12nkirPW6iN2y2RtrD6ERXb1Sws8S');
    expect(saved.keys, containsAll(['donate_wallets.json', 'donate_wallets.json.sig']));

    // The next start has it with no network.
    final next = WalletStore(verify: yes);
    await next.load((name) async => saved[name]);
    expect(next.current.single.address, 'TN3od12nkirPW6iN2y2RtrD6ERXb1Sws8S');

    expect(await WalletStore(verify: no).update(fetch, write), isFalse, reason: 'the signature does not fit');
    final refused = WalletStore(verify: no);
    await refused.load((name) async => saved[name]);
    expect(refused.current, builtInWallets, reason: 'a kept list is checked again');
    expect(await WalletStore(verify: yes).update((u) async => throw StateError('offline'), write), isFalse);
    expect(await WalletStore(verify: yes).update((u) async => u.endsWith('.sig') ? 'signature' : listText(version: 1), write), isFalse,
        reason: 'not newer');
    expect(await WalletStore(keys: const {}, verify: yes).update(fetch, write), isFalse, reason: 'a key this version does not know');
  });

  testWidgets('the page shows the wallets with the copy and the QR buttons', (tester) async {
    await tester.pumpWidget(MaterialApp(home: DonatePage(store: WalletStore(), refresh: () async => false)));
    await tester.pump();
    for (final x in builtInWallets) {
      expect(find.byKey(ValueKey('wallet:${x.kind.name}')), findsOneWidget);
      expect(find.byKey(ValueKey('coin:${x.kind.name}')), findsOneWidget, reason: 'each coin has its icon');
      expect(find.text(x.address), findsOneWidget);
    }
  });
}
