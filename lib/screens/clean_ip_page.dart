import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/clean_ip.dart';
import '../core/link_fields.dart';
import '../core/proxy_config.dart' show ProxyConfig;
import '../core/server_resolver.dart' show systemLookup;
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'share_sheet.dart' show toast;

const _stateFile = 'clean_ip_scan.json';

enum _Sort { fast, loss, speed }

/// How many good addresses are drawn while a scan runs (all of them are kept).
const _liveShown = 30;

/// 10000 as "10,000".
String _grouped(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

typedef _Server = ({String name, LinkFields fields, ProxyConfig config});

/// "Find a clean IP" (see core/clean_ip.dart). Two ways to open it:
/// - from the edit page of a server: [server] is that server; picking an address pops with it;
/// - from the menu of the home page: [state] gives the servers to choose from; addresses can be copied,
///   added as copies of configs, or put in place of a config's address.
/// Either way the scan can also be run on its own, for addresses only, without any server.
///
/// The page has three faces: the setup, the scan while it runs, and the results.
class CleanIpPage extends StatefulWidget {
  const CleanIpPage({super.key, this.server, this.state});

  final LinkFields? server;
  final AppState? state;

  @override
  State<CleanIpPage> createState() => _CleanIpPageState();
}

class _CleanIpPageState extends State<CleanIpPage> {
  // The network: Cloudflare, Fastly or the user's own list (null).
  Cdn? _cdn = Cdn.cloudflare;
  final _custom = TextEditingController();
  final _ports = TextEditingController(text: '443');
  final _sni = TextEditingController();
  var _count = cleanIpTcpCount, _seconds = 2, _stopAfter = 0, _samples = 1;
  // Progress comes for every probe; the screen is redrawn at most this often.
  var _lastPaint = DateTime(0);
  var _gentle = false, _skip = false, _neighbors = false, _fragment = false, _colo = false, _speed = false;
  String? _listError, _numberError, _note;

  // With a server's settings (true) or addresses only (false).
  var _withServer = true;

  // The servers to choose from when opened from the home page.
  late final List<_Server> _servers = _eligible();
  LinkFields? _chosen;

  var _running = false;
  var _cancel = false;
  var _stage = 1, _done = 0, _total = 0;
  var _enriching = false;
  List<CleanIp> _live = [];
  List<CleanIp>? _found;
  var _sort = _Sort.fast;
  // What the last scan was: the server (the "Add" buttons copy it) and how many steps it had.
  LinkFields? _scanned;
  var _scanSteps = 1;
  var _scanEnrich = false;
  String _scanSummary = '';
  // The addresses the user ticked, and the configs they are meant for (a copy of each config is made for
  // each address, or the config's address is replaced).
  final _picked = <String>{};
  final _targets = Set<LinkFields>.identity();

  // A scan that was stopped and can be taken up again.
  ScanState? _saved;
  ({bool server, ScanOptions options, LinkFields? link})? _savedInfo;

  List<_Server> _eligible() {
    final s = widget.state;
    if (s == null) return const [];
    final out = <_Server>[];
    for (final c in s.all) {
      if (c.isOpenVpn) continue;
      final f = LinkFields.parse(c.link);
      if (f != null && const {'vless', 'vmess', 'trojan'}.contains(f.scheme)) {
        out.add((name: c.name, fields: f, config: c));
        if (out.length >= 300) break;
      }
    }
    return out;
  }

  /// The server the scan would use: the one of the edit page, or the one chosen in the list.
  LinkFields? get _server => widget.server ?? _chosen;

  bool get _fixed => widget.server != null;

  String _nameOf(LinkFields? f) {
    if (f == null) return '';
    final e = _servers.where((e) => identical(e.fields, f)).firstOrNull;
    return e?.name ?? f.host;
  }

  @override
  void initState() {
    super.initState();
    if (widget.server == null) {
      final selected = widget.state?.selected;
      final pick = selected == null ? null : _servers.where((e) => e.name == selected.name).firstOrNull;
      _chosen = (pick ?? _servers.firstOrNull)?.fields;
      // With no server in the list there is only the scan of addresses.
      if (_chosen == null) _withServer = false;
    } else {
      _chosen = widget.server;
    }
    _detect();
    _loadSaved();
  }

  @override
  void dispose() {
    _cancel = true;
    for (final c in [_custom, _ports, _sni]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Chooses the CDN the server's name resolves to.
  Future<void> _detect() async {
    final server = _server;
    if (server == null) return;
    final ip = await systemLookup(server.host) ?? server.host;
    final cdn = cdnOf(ip);
    if (mounted && cdn != null) setState(() => _cdn = cdn);
  }

  // ---- a scan that was stopped

  Future<void> _loadSaved() async {
    try {
      final text = await VpnChannel.readFile(_stateFile);
      if (text == null || text.isEmpty) return;
      final j = jsonDecode(text);
      if (j is! Map) return;
      final state = ScanState.fromJson(j['state']);
      if (state == null || state.pending.isEmpty) return;
      final link = j['server'] is String ? LinkFields.parse(j['server'] as String) : null;
      if (mounted) {
        setState(() {
          _saved = state;
          _savedInfo = (server: j['server'] is String, options: ScanOptions.fromJson(j['options']), link: link);
        });
      }
    } catch (_) {}
  }

  void _save(ScanState state, ScanOptions options, LinkFields? server) {
    VpnChannel.writeFile(
            _stateFile,
            jsonEncode({
              'state': state.toJson(),
              'options': options.toJson(),
              if (server != null) 'server': server.build(),
            }))
        .catchError((_) {});
  }

  Future<void> _clearSaved() async {
    VpnChannel.deleteFile(_stateFile).catchError((_) {});
    if (mounted) {
      setState(() {
        _saved = null;
        _savedInfo = null;
      });
    }
  }

  // ---- the scan

  /// The options of the form, or null (with the message set) when the ports cannot be read.
  ScanOptions? _options() {
    final ports = [for (final p in _ports.text.split(RegExp(r'[\s,;]+'))) if (p.isNotEmpty) int.tryParse(p) ?? -1];
    if (!_withServer && (ports.isEmpty || ports.length > cleanIpMaxPorts || ports.any((p) => p < 1 || p > 65535))) {
      setState(() {
        _listError = null;
        _numberError = tr(context, 'cleanIpLimits');
      });
      return null;
    }
    return ScanOptions(
      count: _count,
      timeoutSeconds: _seconds,
      gentle: _gentle,
      ports: ports.isEmpty ? const [443] : ports,
      sni: _sni.text,
      stopAfter: _stopAfter,
      skipFirst: _withServer && _skip,
      neighbors: _neighbors,
      samples: _samples,
      fragment: _fragment,
    );
  }

  String _cdnName(Cdn? c) => switch (c) {
        Cdn.cloudflare => 'Cloudflare',
        Cdn.fastly => 'Fastly',
        null => tr(context, 'cleanIpMyList'),
      };

  Future<void> _scan({ScanState? resume, ScanOptions? resumeOptions, LinkFields? resumeServer}) async {
    FocusScope.of(context).unfocus();
    final options = resume != null ? resumeOptions! : _options();
    if (options == null) return;
    var ranges = <String>[];
    var addresses = <String>[];
    if (resume == null) {
      if (_cdn == null) {
        final targets = parseTargets(_custom.text);
        if (targets.isEmpty) {
          setState(() {
            _numberError = null;
            _listError = targets.bad.isEmpty
                ? tr(context, 'cleanIpBadRange', {'line': ''})
                : tr(context, 'cleanIpBadEntries', {'list': targets.bad.take(3).join(', ')});
          });
          return;
        }
        setState(() {
          _listError = targets.bad.isEmpty ? null : tr(context, 'cleanIpBadEntries', {'list': targets.bad.take(3).join(', ')});
          _numberError = null;
          _note = targets.domains.isEmpty ? null : tr(context, 'cleanIpResolving');
        });
        ranges = targets.ranges;
        addresses = await resolveTargets(targets);
        if (!mounted) return;
        if (ranges.isEmpty && addresses.isEmpty) {
          setState(() => _listError = tr(context, 'cleanIpBadRange', {'line': ''}));
          return;
        }
      } else if (_cdn == Cdn.cloudflare) {
        ranges = await liveCloudflareRanges();
      } else {
        ranges = rangesOf(_cdn!);
      }
    }
    if (!mounted) return;
    final server = resume != null ? resumeServer : (_withServer ? _server : null);
    final cloudflare = _cdn == Cdn.cloudflare;
    final enrich = cloudflare && (_colo || _speed);
    setState(() {
      _listError = _numberError = null;
      _note = null;
      _running = true;
      _cancel = false;
      _found = null;
      _live = [];
      _picked.clear();
      _scanned = server;
      _scanEnrich = enrich;
      _scanSteps = (server != null && !options.skipFirst ? 2 : 1) + (enrich ? 1 : 0);
      _scanSummary = [
        _cdnName(_cdn),
        server == null ? tr(context, 'cleanIpModeOnly') : _nameOf(server),
        if (resume == null) tr(context, 'cleanIpDepthSummary', {'n': options.count, 's': options.timeoutSeconds}),
      ].join(' · ');
      _stage = 1;
      _done = 0;
      _total = 0;
    });
    final found = await scanCleanIps(
      server: server,
      ranges: ranges,
      addresses: addresses,
      options: options,
      resume: resume,
      onProgress: (s, d, t) {
        _stage = s;
        _done = d;
        _total = t;
        _paint(force: d == t);
      },
      onResult: (r) {
        _live.add(r);
        _paint();
      },
      onCheckpoint: (state) => _save(state, options, server),
      cancelled: () => _cancel || !mounted,
    );
    if (!mounted) return;
    if (_cancel) {
      // Stopped by the user: the checkpoint holds what is left, and what was found so far is shown (with
      // nothing found, the setup, where the scan can be resumed).
      setState(() {
        _running = false;
        _enriching = false;
        _found = _live.isEmpty ? null : (_sorted(_live).take(cleanIpKeep * 2).toList());
      });
      _loadSaved();
      return;
    }
    await _clearSaved();
    var results = found;
    if (enrich && results.isNotEmpty) {
      setState(() {
        _enriching = true;
        _done = 0;
        _total = results.length < 20 ? results.length : 20;
        _live = results;
      });
      results = await enrichResults(results,
          colo: _colo,
          speed: _speed,
          onProgress: (d, t) {
            if (mounted) setState(() => _done = d);
          },
          cancelled: () => _cancel || !mounted);
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _enriching = false;
      _found = results;
      _sort = _Sort.fast;
      if (options.stopAfter > 0 && results.length >= options.stopAfter) _note = tr(context, 'cleanIpStopped');
    });
  }

  /// Redraws the scan, at most ten times a second (a scan of thousands reports thousands of times).
  void _paint({bool force = false}) {
    if (!mounted) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastPaint) < const Duration(milliseconds: 100)) return;
    _lastPaint = now;
    setState(() {});
  }

  Future<void> _resume() async {
    final s = _saved, info = _savedInfo;
    if (s == null || info == null) return;
    await _scan(resume: s, resumeOptions: info.options, resumeServer: info.link);
  }

  void _newScan() => setState(() {
        _found = null;
        _live = [];
        _picked.clear();
        _note = null;
      });

  // ---- what to take away

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) toast(context, S.of(context).copied);
  }

  static String _key(CleanIp r) => '${r.ip}:${r.port}';

  static int _ms(CleanIp r) => r.delayMs ?? r.tcpMs;

  List<CleanIp> _sorted(List<CleanIp> list) {
    final out = [...list];
    switch (_sort) {
      case _Sort.fast:
        out.sort((a, b) => _ms(a).compareTo(_ms(b)));
      case _Sort.loss:
        out.sort((a, b) => a.loss != b.loss ? a.loss.compareTo(b.loss) : _ms(a).compareTo(_ms(b)));
      case _Sort.speed:
        out.sort((a, b) {
          final c = (b.downMbps ?? -1).compareTo(a.downMbps ?? -1);
          return c != 0 ? c : _ms(a).compareTo(_ms(b));
        });
    }
    return out;
  }

  List<CleanIp> get _pickedResults => [for (final r in _found ?? _live) if (_picked.contains(_key(r))) r];

  /// The configs the ticked addresses are for: the ones ticked in the list, else the one that was scanned.
  List<LinkFields> get _targetList {
    if (_targets.isNotEmpty) return _targets.toList();
    final one = _scanned ?? _chosen;
    return one == null ? const [] : [one];
  }

  /// Whether addresses can be ticked and put into configs (opened from the home page, with servers).
  bool get _canAct => !_fixed && widget.state != null && _servers.isNotEmpty;

  /// Adds, for each ticked config, a copy with each of [list]'s addresses.
  Future<void> _addServers(List<CleanIp> list) async {
    final state = widget.state;
    if (state == null || list.isEmpty) return;
    final links = [for (final base in _targetList) ...linksFor(base, list)];
    if (links.isEmpty) return;
    final added = state.addCleanIps(links);
    if (mounted) toast(context, tr(context, 'cleanIpAddedMany', {'n': added}));
  }

  /// Puts the one ticked address into each ticked config itself (its address is replaced).
  Future<void> _replaceAddress(CleanIp r) async {
    final state = widget.state;
    if (state == null) return;
    var changed = 0;
    String? first;
    for (final base in _targetList) {
      final entry = _servers.where((e) => identical(e.fields, base)).firstOrNull;
      final copy = withCleanIp(base, r.ip);
      if (entry == null || copy == null) continue;
      final group = state.groups.where((g) => g.configs.contains(entry.config)).firstOrNull;
      if (group == null) continue;
      if (await state.editConfig(group, entry.config, copy.build())) {
        changed++;
        first ??= entry.name;
      }
    }
    if (mounted) {
      toast(context, changed == 0 ? S.of(context).invalidConfig : tr(context, 'cleanIpReplaced', {'name': changed > 1 ? '$first +${changed - 1}' : first!}));
    }
    // The configs were rebuilt: the ticks on the old ones no longer point at anything.
    if (mounted) setState(_targets.clear);
  }

  Future<void> _loadFile() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'csv', 'list'], withData: true);
      final bytes = r?.files.single.bytes;
      if (bytes == null) return;
      final text = utf8.decode(bytes, allowMalformed: true);
      setState(() => _custom.text = _custom.text.isEmpty ? text : '${_custom.text}\n$text');
    } catch (_) {}
  }

  // ---- sheets

  /// A bottom sheet with a search field over [_servers]; [tile] draws one server.
  Future<void> _serverSheet({required String title, required Widget Function(_Server e, StateSetter setSheet) tile}) {
    var query = '';
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final q = query.trim().toLowerCase();
          final list = q.isEmpty ? _servers : _servers.where((e) => e.name.toLowerCase().contains(q)).toList();
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.75,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
              if (_servers.length > 6)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: tr(context, 'cleanIpSearch'),
                      prefixIcon: const Icon(Icons.search),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => setSheet(() => query = v),
                  ),
                ),
              Expanded(
                child: list.isEmpty
                    ? Center(child: Text(tr(context, 'cleanIpNoMatch')))
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (context, i) => tile(list[i], setSheet),
                      ),
              ),
            ]),
          );
        },
      ),
    );
  }

  Future<void> _pickServer() => _serverSheet(
        title: tr(context, 'cleanIpPickServer'),
        tile: (e, _) => ListTile(
          leading: Icon(identical(e.fields, _chosen) ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: identical(e.fields, _chosen) ? Theme.of(context).colorScheme.primary : null),
          title: Text(e.name, overflow: TextOverflow.ellipsis),
          subtitle: Text(e.fields.host, overflow: TextOverflow.ellipsis, textDirection: TextDirection.ltr),
          onTap: () {
            Navigator.pop(context);
            setState(() => _chosen = e.fields);
            _detect();
          },
        ),
      );

  bool _isTarget(LinkFields f) => _targets.contains(f) || (_targets.isEmpty && identical(f, _scanned ?? _chosen));

  Future<void> _pickTargets() async {
    await _serverSheet(
      title: tr(context, 'cleanIpPutIn'),
      tile: (e, setSheet) => CheckboxListTile(
        value: _isTarget(e.fields),
        title: Text(e.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(e.fields.host, overflow: TextOverflow.ellipsis, textDirection: TextDirection.ltr),
        onChanged: (v) {
          // Ticking starts from what was shown ticked (the scanned config).
          if (_targets.isEmpty) {
            final one = _scanned ?? _chosen;
            if (one != null) _targets.add(one);
          }
          v == true ? _targets.add(e.fields) : _targets.remove(e.fields);
          setSheet(() {});
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(builder: (context, setSheet) {
        void update(VoidCallback f) {
          setState(f);
          setSheet(() {});
        }

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text(tr(context, 'cleanIpAdvanced'), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _option(Icons.spa_outlined, _gentle, 'cleanIpGentle', 'cleanIpGentleDesc', (v) => update(() => _gentle = v)),
              _option(Icons.content_cut, _fragment, 'cleanIpFragment', 'cleanIpFragmentDesc', (v) => update(() => _fragment = v)),
              _option(Icons.hub_outlined, _neighbors, 'cleanIpNeighbors', null, (v) => update(() => _neighbors = v)),
              if (_withServer)
                _option(Icons.fast_forward_outlined, _skip, 'cleanIpSkip', 'cleanIpSkipDesc', (v) => update(() => _skip = v)),
              if (_cdn == Cdn.cloudflare) ...[
                _option(Icons.location_on_outlined, _colo, 'cleanIpColo', null, (v) => update(() => _colo = v)),
                _option(Icons.speed, _speed, 'cleanIpSpeed', null, (v) => update(() => _speed = v)),
              ],
              const Divider(height: 24),
              _stepper(
                icon: Icons.flag_outlined,
                label: tr(context, 'cleanIpStopAfter'),
                value: _stopAfter,
                show: (v) => v == 0 ? tr(context, 'cleanIpNever') : '$v',
                down: _stopAfter > 0 ? () => update(() => _stopAfter = _stopAfter <= 5 ? _stopAfter - 1 : _stopAfter - 5) : null,
                up: _stopAfter < 100 ? () => update(() => _stopAfter = _stopAfter < 5 ? _stopAfter + 1 : _stopAfter + 5) : null,
              ),
              _stepper(
                icon: Icons.repeat,
                label: tr(context, 'cleanIpSamples'),
                value: _samples,
                down: _samples > 1 ? () => update(() => _samples--) : null,
                up: _samples < cleanIpMaxSamples ? () => update(() => _samples++) : null,
              ),
            ],
          ),
        );
      }),
    );
  }

  /// The options that are on, for the summary on the Options card.
  String _optionsSummary() {
    final on = <String>[
      if (_gentle) tr(context, 'cleanIpGentle'),
      if (_fragment) tr(context, 'cleanIpFragmentShort'),
      if (_neighbors) tr(context, 'cleanIpNeighborsShort'),
      if (_withServer && _skip) tr(context, 'cleanIpSkip'),
      if (_cdn == Cdn.cloudflare && _colo) tr(context, 'cleanIpColoShort'),
      if (_cdn == Cdn.cloudflare && _speed) tr(context, 'cleanIpSpeedShort'),
      if (_stopAfter > 0) '${tr(context, 'cleanIpStopAfterShort')} $_stopAfter',
      if (_samples > 1) '${tr(context, 'cleanIpSamplesShort')} $_samples',
    ];
    return on.isEmpty ? tr(context, 'cleanIpDefaults') : on.join(', ');
  }

  // ---- pieces of the page

  Widget _option(IconData icon, bool value, String title, String? desc, ValueChanged<bool> onChanged) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: Icon(icon),
        value: value,
        onChanged: onChanged,
        title: Text(tr(context, title)),
        subtitle: desc == null ? null : Text(tr(context, desc)),
      );

  Widget _stepper({
    required IconData icon,
    required String label,
    required int value,
    String Function(int)? show,
    VoidCallback? down,
    VoidCallback? up,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(child: Text(label)),
          IconButton.outlined(onPressed: down, icon: const Icon(Icons.remove), visualDensity: VisualDensity.compact),
          SizedBox(
            width: 56,
            child: Text(show?.call(value) ?? '$value',
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          ),
          IconButton.outlined(onPressed: up, icon: const Icon(Icons.add), visualDensity: VisualDensity.compact),
        ]),
      );

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _latency(int ms) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final MaterialColor c = ms <= 300 ? Colors.green : (ms <= 700 ? Colors.orange : Colors.red);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: dark ? 0.22 : 0.14), borderRadius: BorderRadius.circular(20)),
      child: Text('$ms ms',
          textDirection: TextDirection.ltr,
          style: TextStyle(color: dark ? c.shade200 : c.shade800, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }

  String _details(CleanIp r) => <String>[
        if (r.loss > 0) tr(context, 'cleanIpLoss', {'loss': (r.loss * 100).round()}),
        if (r.jitterMs > 0) 'jitter ${r.jitterMs} ms',
        if (r.colo != null) r.colo!,
        if (r.downMbps != null) tr(context, 'cleanIpSpeedRow', {'mbps': r.downMbps!.toStringAsFixed(1), 'ttfb': r.ttfbMs ?? 0}),
      ].join(' · ');

  Widget _result(CleanIp r, int rank, {required bool selectable}) {
    final scheme = Theme.of(context).colorScheme;
    final picked = _picked.contains(_key(r));
    final details = _details(r);
    void toggle() => setState(() => picked ? _picked.remove(_key(r)) : _picked.add(_key(r)));
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: picked ? scheme.secondaryContainer : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: selectable ? toggle : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          child: Row(children: [
            if (selectable)
              Checkbox(value: picked, onChanged: (_) => toggle())
            else
              SizedBox(
                width: 40,
                child: Text('$rank', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r.ip}:${r.port}',
                    textDirection: TextDirection.ltr,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontFamily: 'monospace')),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(details,
                      textDirection: TextDirection.ltr,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            _latency(_ms(r)),
            if (_fixed && !_running) ...[
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: () => Navigator.pop(context, r.ip), child: Text(tr(context, 'cleanIpUse'))),
            ] else
              IconButton(tooltip: tr(context, 'cleanIpCopy'), onPressed: () => _copy(r.ip), icon: const Icon(Icons.copy, size: 20)),
          ]),
        ),
      ),
    );
  }

  /// The longest the first stage can take (every address waiting its whole timeout), as a hint.
  String _estimate() {
    final ports = _withServer ? 1 : _ports.text.split(RegExp(r'[\s,;]+')).where((p) => p.isNotEmpty).length.clamp(1, cleanIpMaxPorts).toInt();
    final probes = _count * _samples * ports;
    final wait = _gentle ? (_seconds < gentleMinTimeout ? gentleMinTimeout : _seconds) : _seconds;
    var seconds = probes * wait / cleanIpWorkers(probes, gentle: _gentle);
    if (_gentle && probes / gentleProbesPerSecond > seconds) seconds = probes / gentleProbesPerSecond;
    final minutes = (seconds / 60).ceil();
    return minutes <= 1 ? tr(context, 'cleanIpEstimateShort') : tr(context, 'cleanIpEstimate', {'m': minutes});
  }

  // ---- the three faces

  Widget _setup() {
    final scheme = Theme.of(context).colorScheme;
    final canPickServer = _fixed || _servers.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (_saved != null)
          Card(
            color: scheme.secondaryContainer,
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.history),
              title: Text(tr(context, 'cleanIpResume', {'n': _saved!.pending.length})),
              trailing: TextButton(onPressed: _clearSaved, child: Text(tr(context, 'cleanIpDiscard'))),
              onTap: _resume,
            ),
          ),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
                value: true,
                icon: const Icon(Icons.dns_outlined),
                label: Text(tr(context, 'cleanIpModeServer')),
                enabled: canPickServer),
            ButtonSegment(value: false, icon: const Icon(Icons.public), label: Text(tr(context, 'cleanIpModeOnly'))),
          ],
          selected: {_withServer},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _withServer = v.first),
        ),
        if (_withServer) ...[
          _section(tr(context, 'cleanIpPickServer')),
          if (!canPickServer)
            Text(tr(context, 'cleanIpNoServers'))
          else
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(_fixed ? _server!.host : _nameOf(_chosen), overflow: TextOverflow.ellipsis),
                subtitle: _fixed || _chosen == null
                    ? null
                    : Text(_chosen!.host, overflow: TextOverflow.ellipsis, textDirection: TextDirection.ltr),
                trailing: _fixed ? null : const Icon(Icons.unfold_more),
                onTap: _fixed ? null : _pickServer,
              ),
            ),
        ],
        _section(tr(context, 'cleanIpNetwork')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in const [Cdn.cloudflare, Cdn.fastly, null])
            ChoiceChip(
              label: Text(_cdnName(c)),
              selected: _cdn == c,
              onSelected: (_) => setState(() => _cdn = c),
            ),
        ]),
        if (_cdn == null) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _custom,
            maxLines: 6,
            minLines: 3,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: tr(context, 'cleanIpList'),
              helperText: tr(context, 'cleanIpListHint'),
              helperMaxLines: 4,
              errorText: _listError,
              border: const OutlineInputBorder(),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(onPressed: _loadFile, icon: const Icon(Icons.file_open_outlined), label: Text(tr(context, 'cleanIpFile'))),
          ),
        ],
        if (!_withServer) ...[
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: _ports,
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: tr(context, 'cleanIpPorts'), border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _sni,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: tr(context, 'cleanIpSni'),
                  helperText: tr(context, 'cleanIpSniHint'),
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ]),
        ],
        // A user list sets its own addresses; the number only says how many are drawn from ranges.
        _section(tr(context, 'cleanIpHowMany')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final n in cleanIpCountChoices)
            ChoiceChip(
              label: Text(_grouped(n), textDirection: TextDirection.ltr),
              selected: _count == n,
              onSelected: (_) => setState(() => _count = n),
            ),
        ]),
        _section(tr(context, 'cleanIpTimeout')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in cleanIpTimeoutChoices)
            ChoiceChip(
              label: Text(tr(context, 'cleanIpSeconds', {'s': s})),
              selected: _seconds == s,
              onSelected: (_) => setState(() => _seconds = s),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.schedule, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(_estimate(), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.tune),
            title: Text(tr(context, 'cleanIpAdvanced')),
            subtitle: Text(_optionsSummary(), maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openOptions,
          ),
        ),
        if (_numberError != null) ...[
          const SizedBox(height: 12),
          Text(_numberError!, style: TextStyle(color: scheme.error)),
        ],
        if (_note != null) ...[
          const SizedBox(height: 12),
          Text(_note!),
        ],
      ],
    );
  }

  int get _stepNow {
    if (_enriching) return _scanSteps;
    if (_stage == 2) return _scanSteps - (_scanEnrich ? 1 : 0);
    return 1;
  }

  Widget _scanning() {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final title = _enriching ? 'cleanIpStageEnrichTitle' : (_stage == 1 ? 'cleanIpStage1Title' : 'cleanIpStage2Title');
    final shown = _sorted(_live).take(_liveShown).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(tr(context, 'cleanIpStep', {'n': _stepNow, 'total': _scanSteps}),
                      style: text.labelLarge?.copyWith(color: scheme.primary)),
                ),
                if (_total > 0) Text('$_done / $_total', textDirection: TextDirection.ltr, style: text.labelLarge),
              ]),
              const SizedBox(height: 6),
              Text(tr(context, title), style: text.titleMedium),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _total > 0 ? _done / _total : null,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Icon(Icons.check_circle_outline, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(child: Text(tr(context, 'cleanIpLiveTitle', {'n': _live.length}))),
              ]),
              if (_scanSummary.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(_scanSummary, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 12),
        for (final (i, r) in shown.indexed) _result(r, i + 1, selectable: false),
      ],
    );
  }

  Widget _results() {
    final scheme = Theme.of(context).colorScheme;
    final found = _found ?? const <CleanIp>[];
    if (found.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.search_off, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(tr(context, 'cleanIpNone'), textAlign: TextAlign.center),
            if (_note != null) ...[const SizedBox(height: 8), Text(_note!, textAlign: TextAlign.center)],
          ]),
        ),
      );
    }
    final shown = _sorted(found);
    final hasSpeed = found.any((r) => r.downMbps != null);
    final hasLoss = found.any((r) => r.loss > 0);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (_scanSummary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_scanSummary, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        if (_note != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_note!)),
        if (hasSpeed || hasLoss)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(
                  label: Text(tr(context, 'cleanIpSortFast')), selected: _sort == _Sort.fast, onSelected: (_) => setState(() => _sort = _Sort.fast)),
              if (hasLoss)
                ChoiceChip(
                    label: Text(tr(context, 'cleanIpSortLoss')), selected: _sort == _Sort.loss, onSelected: (_) => setState(() => _sort = _Sort.loss)),
              if (hasSpeed)
                ChoiceChip(
                    label: Text(tr(context, 'cleanIpSortSpeed')),
                    selected: _sort == _Sort.speed,
                    onSelected: (_) => setState(() => _sort = _Sort.speed)),
            ]),
          ),
        if (_canAct)
          Row(children: [
            Expanded(
              child: Text(tr(context, 'cleanIpPicked', {'n': _picked.length, 'total': found.length}),
                  style: TextStyle(color: scheme.primary)),
            ),
            TextButton(
                onPressed: () => setState(() {
                      if (_picked.length == found.length) {
                        _picked.clear();
                      } else {
                        _picked
                          ..clear()
                          ..addAll(found.map(_key));
                      }
                    }),
                child: Text(tr(context, _picked.length == found.length ? 'cleanIpSelectNone' : 'cleanIpSelectAll'))),
          ]),
        for (final (i, r) in shown.indexed) _result(r, i + 1, selectable: _canAct),
      ],
    );
  }

  Widget _bottomBar() {
    final Widget child;
    if (_running) {
      child = OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: _cancel ? null : () => setState(() => _cancel = true),
        icon: const Icon(Icons.stop_circle_outlined),
        label: Text(tr(context, 'cleanIpStop')),
      );
    } else if (_found != null) {
      final acting = _canAct && _picked.isNotEmpty && (_found ?? const []).isNotEmpty;
      child = acting
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: Text(tr(context, 'cleanIpPicked', {'n': _picked.length, 'total': _found!.length}),
                      style: Theme.of(context).textTheme.labelLarge),
                ),
                TextButton.icon(
                  onPressed: _pickTargets,
                  icon: const Icon(Icons.dns_outlined, size: 18),
                  label: Text(tr(context, 'cleanIpConfigs', {'n': _targetList.length})),
                ),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: _targetList.isEmpty ? null : () => _addServers(_pickedResults),
                    icon: const Icon(Icons.playlist_add),
                    label: Text(tr(context, 'cleanIpAddPicked', {'n': _picked.length * _targetList.length}),
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _picked.length == 1 && _targetList.isNotEmpty ? () => _replaceAddress(_pickedResults.single) : null,
                  icon: const Icon(Icons.swap_horiz),
                  label: Text(tr(context, 'cleanIpReplaceShort')),
                ),
              ]),
            ])
          : FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _newScan,
              icon: const Icon(Icons.refresh),
              label: Text(tr(context, 'cleanIpNewScan')),
            );
    } else {
      final ready = !(_withServer && _server == null);
      child = FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: ready ? _scan : null,
        icon: const Icon(Icons.radar),
        label: Text(tr(context, 'cleanIpStart')),
      );
    }
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: child),
      ),
    );
  }

  void _about() => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr(context, 'cleanIpTitle')),
          content: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(tr(context, 'cleanIpModeServer'), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(tr(context, 'cleanIpDesc')),
              const SizedBox(height: 16),
              Text(tr(context, 'cleanIpModeOnly'), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(tr(context, 'cleanIpOnlyDesc')),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(MaterialLocalizations.of(context).okButtonLabel))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final results = _found != null && !_running;
    final shown = _found ?? const <CleanIp>[];
    final links = _targetList.isEmpty ? const <String>[] : [for (final b in _targetList) ...linksFor(b, _picked.isEmpty ? shown : _pickedResults)];
    return PopScope(
      // From the results, Back goes to the setup of a new scan.
      canPop: !results,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && results) _newScan();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(results && shown.isNotEmpty ? tr(context, 'cleanIpResultsTitle', {'n': shown.length}) : tr(context, 'cleanIpTitle')),
          actions: [
            if (results && shown.isNotEmpty)
              PopupMenuButton<String>(
                icon: const Icon(Icons.copy_all),
                tooltip: tr(context, 'cleanIpCopy'),
                onSelected: (v) => switch (v) {
                  'ip' => _copy(endpointsText(_picked.isEmpty ? shown : _pickedResults)),
                  'links' => _copy(links.join('\n')),
                  _ => _copy(subscriptionText(links)),
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'ip', child: Text(tr(context, 'cleanIpCopyEndpoints'))),
                  if (links.isNotEmpty) ...[
                    PopupMenuItem(value: 'links', child: Text(tr(context, 'cleanIpCopyLinks'))),
                    PopupMenuItem(value: 'sub', child: Text(tr(context, 'cleanIpCopySub'))),
                  ],
                ],
              ),
            if (!results && !_running)
              IconButton(tooltip: tr(context, 'cleanIpAbout'), onPressed: _about, icon: const Icon(Icons.info_outline)),
          ],
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: KeyedSubtree(
            key: ValueKey(_running ? 'scan' : (results ? 'results' : 'setup')),
            child: _running ? _scanning() : (results ? _results() : _setup()),
          ),
        ),
        bottomNavigationBar: _bottomBar(),
      ),
    );
  }
}
