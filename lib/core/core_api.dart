import 'dart:convert';
import 'dart:io';

/// The running core's local control API (Clash-compatible), reachable on loopback only and
/// protected by a random secret.
class CoreApi {
  CoreApi(this.port, this.secret);

  final int port;
  final String secret;

  Future<dynamic> get(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port$path'))
          .timeout(const Duration(seconds: 3));
      req.headers.set('Authorization', 'Bearer $secret');
      final res = await req.close().timeout(const Duration(seconds: 4));
      final body = await res.transform(utf8.decoder).join();
      return res.statusCode == 200 ? jsonDecode(body) : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> delete(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.deleteUrl(Uri.parse('http://127.0.0.1:$port$path'));
      req.headers.set('Authorization', 'Bearer $secret');
      await (await req.close()).drain<void>();
    } catch (_) {
      // the connection may already be gone
    } finally {
      client.close(force: true);
    }
  }
}

/// One entry of the live connection list.
class LiveConnection {
  LiveConnection(this.id, this.host, this.port, this.network, this.chain, this.rule,
      this.process, this.up, this.down, this.start);

  final String id;
  final String host;
  final int port;
  final String network;
  final String chain;
  final String rule;
  final String process;
  final int up;
  final int down;
  final DateTime start;

  static LiveConnection? from(Object? j) {
    if (j is! Map) return null;
    final m = (j['metadata'] as Map?) ?? const {};
    final host = '${m['host'] ?? ''}'.isNotEmpty
        ? '${m['host']}'
        : '${m['destinationIP'] ?? '?'}';
    final path = '${m['processPath'] ?? ''}';
    final chains = (j['chains'] as List?)?.map((e) => '$e').toList() ?? const [];
    return LiveConnection(
      '${j['id']}',
      host,
      int.tryParse('${m['destinationPort']}') ?? 0,
      '${m['network'] ?? ''}',
      chains.isEmpty ? '' : chains.first,
      '${j['rule'] ?? ''}',
      path.isEmpty ? '' : path.split(RegExp(r'[\\/]')).last,
      (j['upload'] as num?)?.toInt() ?? 0,
      (j['download'] as num?)?.toInt() ?? 0,
      DateTime.tryParse('${j['start']}') ?? DateTime.now(),
    );
  }
}
