import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

import 'sub_formats.dart' show extractSubscriptionLinks;
import 'sub_surge.dart' show subscriptionDeepLink;

/// Links and files that other programs open with Kumo (`vless://...` in a browser or a chat, a shared
/// text, a file). Nothing in here adds anything: the app first shows [summarizeExternal] and asks.

/// What the user is asked about: a subscription (its host), or a number of server links.
typedef ExternalSummary = ({String? host, int servers});

/// What [text] holds that Kumo can add, or null when nothing.
ExternalSummary? summarizeExternal(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final first = t.split(RegExp(r'\s')).first;
  final deep = subscriptionDeepLink(first);
  final address = deep?.url ?? first;
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(address)) {
    final host = Uri.tryParse(address)?.host ?? '';
    // A page address among other text is not a subscription; a single address is.
    if (host.isNotEmpty && (deep != null || t == first)) return (host: host, servers: 0);
  }
  final n = extractSubscriptionLinks(t).length;
  return n == 0 ? null : (host: null, servers: n);
}

/// macOS: the system hands links and files to the app through its delegate (macos/Runner/AppDelegate.swift),
/// which keeps them until they are asked for here.
class MacExternal {
  static const _channel = MethodChannel('kumo/external');

  /// What was handed over since the last call.
  static Future<List<String>> take() async {
    try {
      final items = await _channel.invokeListMethod<String>('take');
      return (items ?? const <String>[]).take(ExternalInbox.maxItems).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Called when something is handed over while the app runs.
  static void onExternal(void Function() callback) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'external') callback();
      return null;
    });
  }
}

/// How programs on a computer hand things to the running Kumo: a copy started with a link or a file
/// on its command line writes it into the data folder and ends; the running copy picks it up.
class ExternalInbox {
  static const fileName = 'external-open.json';
  static const maxItems = 20;
  static const maxBytes = 1000000;

  static final _link = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://');

  /// The links and the contents of the files among the command line [args] (options are skipped).
  static Future<List<String>> fromArgs(List<String> args) async {
    final out = <String>[];
    for (final a in args) {
      if (out.length >= maxItems) break;
      final arg = a.trim();
      if (arg.isEmpty || arg.startsWith('--')) continue;
      if (_link.hasMatch(arg)) {
        out.add(arg);
        continue;
      }
      try {
        final f = File(arg);
        if (await f.exists() && await f.length() <= maxBytes) {
          out.add(utf8.decode(await f.readAsBytes(), allowMalformed: true));
        }
      } catch (_) {}
    }
    return out;
  }

  /// Leaves [items] for the running copy.
  static Future<void> send(String dir, List<String> items) async {
    if (items.isEmpty) return;
    try {
      final f = File('$dir/$fileName');
      final old = await take(dir);
      await f.writeAsString(jsonEncode([...old, ...items].take(maxItems).toList()), flush: true);
    } catch (_) {}
  }

  /// What was left for this copy (once), or an empty list.
  static Future<List<String>> take(String dir) async {
    try {
      final f = File('$dir/$fileName');
      if (!await f.exists()) return const [];
      final text = await f.readAsString();
      await f.delete();
      final j = jsonDecode(text);
      return j is List ? j.whereType<String>().take(maxItems).toList() : const [];
    } catch (_) {
      return const [];
    }
  }
}
