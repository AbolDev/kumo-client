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

/// "Find a clean IP" (see core/clean_ip.dart). Two ways to open it:
/// - from the edit page of a server: [server] is that server; picking an address pops with it;
/// - from the menu of the home page: [state] gives the servers to choose from; an address can be copied,
///   or added as a copy of the server.
/// Either way the scan can also be run on its own, for addresses only, without any server.
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
  final _count = TextEditingController(text: '$cleanIpTcpCount');
  final _timeout = TextEditingController(text: '2');
  final _ports = TextEditingController(text: '443');
  final _sni = TextEditingController();
  final _stopAfter = TextEditingController(text: '0');
  final _samples = TextEditingController(text: '1');
  var _gentle = false, _skip = false, _neighbors = false, _fragment = false, _colo = false, _speed = false;
  String? _listError, _numberError, _note;

  // With a server's settings (true) or addresses only (false).
  var _withServer = true;

  // The servers to choose from when opened from the home page.
  late final List<({String name, LinkFields fields, ProxyConfig config})> _servers = _eligible();
  LinkFields? _chosen;

  var _running = false;
  var _cancel = false;
  var _stage = 1, _done = 0, _total = 0;
  var _enriching = false;
  List<CleanIp> _live = [];
  List<CleanIp>? _found;
  // What the last scan was, to know what the "Add" buttons copy.
  LinkFields? _scanned;
  // The addresses the user ticked, and the config they are meant for (a copy of it is made for each, or its
  // address is replaced).
  final _picked = <String>{};
  final _targets = Set<LinkFields>.identity();

  // A scan that was stopped and can be taken up again.
  ScanState? _saved;
  ({bool server, ScanOptions options, LinkFields? link})? _savedInfo;

  List<({String name, LinkFields fields, ProxyConfig config})> _eligible() {
    final s = widget.state;
    if (s == null) return const [];
    final out = <({String name, LinkFields fields, ProxyConfig config})>[];
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
    for (final c in [_custom, _count, _timeout, _ports, _sni, _stopAfter, _samples]) {
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

  /// The numbers of the form, or null (with the message set) when one is outside its limits.
  ScanOptions? _options() {
    final count = int.tryParse(_count.text.trim()) ?? -1;
    final seconds = int.tryParse(_timeout.text.trim()) ?? -1;
    final stop = int.tryParse(_stopAfter.text.trim()) ?? -1;
    final samples = int.tryParse(_samples.text.trim()) ?? -1;
    final ports = [for (final p in _ports.text.split(RegExp(r'[\s,;]+'))) if (p.isNotEmpty) int.tryParse(p) ?? -1];
    final bad = count < cleanIpMinCount ||
        count > cleanIpMaxCount ||
        seconds < cleanIpMinTimeout ||
        seconds > cleanIpMaxTimeout ||
        stop < 0 ||
        samples < 1 ||
        samples > cleanIpMaxSamples ||
        (!_withServer && (ports.isEmpty || ports.length > cleanIpMaxPorts || ports.any((p) => p < 1 || p > 65535)));
    if (bad) {
      setState(() {
        _listError = null;
        _numberError = tr(context, 'cleanIpLimits');
      });
      return null;
    }
    return ScanOptions(
      count: count,
      timeoutSeconds: seconds,
      gentle: _gentle,
      ports: ports.isEmpty ? const [443] : ports,
      sni: _sni.text,
      stopAfter: stop,
      skipFirst: _withServer && _skip,
      neighbors: _neighbors,
      samples: samples,
      fragment: _fragment,
    );
  }

  Future<void> _scan({ScanState? resume, ScanOptions? resumeOptions, LinkFields? resumeServer}) async {
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
    final server = resume != null ? resumeServer : (_withServer ? _server : null);
    final cloudflare = _cdn == Cdn.cloudflare;
    setState(() {
      _listError = _numberError = null;
      _note = null;
      _running = true;
      _cancel = false;
      _found = null;
      _live = [];
      _picked.clear();
      _scanned = server;
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
        if (mounted) {
          setState(() {
            _stage = s;
            _done = d;
            _total = t;
          });
        }
      },
      onResult: (r) {
        if (mounted) setState(() => _live = [..._live, r]);
      },
      onCheckpoint: (state) => _save(state, options, server),
      cancelled: () => _cancel || !mounted,
    );
    if (!mounted) return;
    if (_cancel) {
      // Stopped by the user: the checkpoint holds what is left.
      setState(() => _running = false);
      _loadSaved();
      return;
    }
    await _clearSaved();
    var results = found;
    if (cloudflare && (_colo || _speed) && results.isNotEmpty) {
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
      if (options.stopAfter > 0 && results.length >= options.stopAfter) _note = tr(context, 'cleanIpStopped');
    });
  }

  Future<void> _resume() async {
    final s = _saved, info = _savedInfo;
    if (s == null || info == null) return;
    await _scan(resume: s, resumeOptions: info.options, resumeServer: info.link);
  }

  // ---- what to take away

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) toast(context, S.of(context).copied);
  }

  static String _key(CleanIp r) => '${r.ip}:${r.port}';

  List<CleanIp> get _pickedResults => [for (final r in _found ?? _live) if (_picked.contains(_key(r))) r];

  /// The configs the ticked addresses are for: the ones ticked in the list, else the one that was scanned.
  List<LinkFields> get _targetList {
    if (_targets.isNotEmpty) return _targets.toList();
    final one = _scanned ?? _chosen;
    return one == null ? const [] : [one];
  }

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

  // ---- the page

  Widget _number(TextEditingController c, String label, {String? helper}) => TextField(
        controller: c,
        enabled: !_running,
        keyboardType: TextInputType.number,
        textDirection: TextDirection.ltr,
        decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 2, border: const OutlineInputBorder()),
      );

  Widget _switch(bool value, String title, String? subtitle, ValueChanged<bool> onChanged) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: _running ? null : onChanged,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
      );

  String _rowText(CleanIp r) {
    final parts = <String>[
      '${r.delayMs ?? r.tcpMs} ms',
      if (r.loss > 0) tr(context, 'cleanIpLoss', {'loss': (r.loss * 100).round()}),
      if (r.jitterMs > 0) 'jitter ${r.jitterMs} ms',
      if (r.colo != null) r.colo!,
      if (r.downMbps != null) tr(context, 'cleanIpSpeedRow', {'mbps': r.downMbps!.toStringAsFixed(1), 'ttfb': r.ttfbMs ?? 0}),
    ];
    return parts.join(' · ');
  }

  Widget _row(CleanIp r, {required bool fixed}) => Card(
        child: ListTile(
          leading: fixed || widget.state == null
              ? null
              : Checkbox(
                  value: _picked.contains(_key(r)),
                  onChanged: _running
                      ? null
                      : (v) => setState(() => v == true ? _picked.add(_key(r)) : _picked.remove(_key(r)))),
          title: Text('${r.ip}:${r.port}', textDirection: TextDirection.ltr),
          subtitle: Text(_rowText(r), textDirection: TextDirection.ltr),
          trailing: Wrap(spacing: 4, children: [
            IconButton(tooltip: tr(context, 'cleanIpCopy'), onPressed: () => _copy(r.ip), icon: const Icon(Icons.copy)),
            if (fixed) FilledButton.tonal(onPressed: () => Navigator.pop(context, r.ip), child: Text(tr(context, 'cleanIpUse'))),
          ]),
          onTap: fixed || widget.state == null || _running
              ? null
              : () => setState(() => _picked.contains(_key(r)) ? _picked.remove(_key(r)) : _picked.add(_key(r))),
        ),
      );
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fixed = widget.server != null;
    final canPickServer = fixed || _servers.isNotEmpty;
    final shown = _found ?? _live;
    final cloudflare = _cdn == Cdn.cloudflare;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'cleanIpTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr(context, _withServer ? 'cleanIpDesc' : 'cleanIpOnlyDesc')),
          const SizedBox(height: 16),
          if (_saved != null && !_running)
            Card(
              color: scheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.restore),
                title: Text(tr(context, 'cleanIpResume', {'n': _saved!.pending.length})),
                trailing: TextButton(onPressed: _clearSaved, child: Text(tr(context, 'cleanIpDiscard'))),
                onTap: _resume,
              ),
            ),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text(tr(context, 'cleanIpModeServer')), enabled: canPickServer),
              ButtonSegment(value: false, label: Text(tr(context, 'cleanIpModeOnly'))),
            ],
            selected: {_withServer},
            onSelectionChanged: _running ? null : (v) => setState(() => _withServer = v.first),
          ),
          if (!canPickServer && _withServer) ...[
            const SizedBox(height: 8),
            Text(tr(context, 'cleanIpNoServers')),
          ],
          const SizedBox(height: 16),
          if (_withServer && !fixed && _servers.isNotEmpty) ...[
            DropdownButtonFormField<LinkFields>(
              value: _chosen,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr(context, 'cleanIpPickServer'), border: const OutlineInputBorder()),
              items: [
                for (final e in _servers) DropdownMenuItem(value: e.fields, child: Text(e.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _running
                  ? null
                  : (v) {
                      setState(() => _chosen = v);
                      _detect();
                    },
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<Cdn?>(
            value: _cdn,
            decoration: InputDecoration(labelText: tr(context, 'cleanIpNetwork'), border: const OutlineInputBorder()),
            items: [
              const DropdownMenuItem(value: Cdn.cloudflare, child: Text('Cloudflare')),
              const DropdownMenuItem(value: Cdn.fastly, child: Text('Fastly')),
              DropdownMenuItem(value: null, child: Text(tr(context, 'cleanIpCustom'))),
            ],
            onChanged: _running ? null : (v) => setState(() => _cdn = v),
          ),
          if (_cdn == null) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _custom,
              enabled: !_running,
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
              child: TextButton.icon(
                  onPressed: _running ? null : _loadFile, icon: const Icon(Icons.file_open), label: Text(tr(context, 'cleanIpFile'))),
            ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _number(_count, tr(context, 'cleanIpCount'))),
            const SizedBox(width: 12),
            Expanded(child: _number(_timeout, tr(context, 'cleanIpTimeout'))),
          ]),
          if (!_withServer) ...[
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _number(_ports, tr(context, 'cleanIpPorts'))),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _sni,
                  enabled: !_running,
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
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(tr(context, 'cleanIpAdvanced')),
            children: [
              _switch(_gentle, tr(context, 'cleanIpGentle'), tr(context, 'cleanIpGentleDesc'), (v) => setState(() => _gentle = v)),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _number(_stopAfter, tr(context, 'cleanIpStopAfter'), helper: tr(context, 'cleanIpStopAfterHint'))),
                const SizedBox(width: 12),
                Expanded(child: _number(_samples, tr(context, 'cleanIpSamples'))),
              ]),
              if (_withServer)
                _switch(_skip, tr(context, 'cleanIpSkip'), tr(context, 'cleanIpSkipDesc'), (v) => setState(() => _skip = v)),
              _switch(_neighbors, tr(context, 'cleanIpNeighbors'), null, (v) => setState(() => _neighbors = v)),
              _switch(_fragment, tr(context, 'cleanIpFragment'), tr(context, 'cleanIpFragmentDesc'),
                  (v) => setState(() => _fragment = v)),
              if (cloudflare) ...[
                _switch(_colo, tr(context, 'cleanIpColo'), null, (v) => setState(() => _colo = v)),
                _switch(_speed, tr(context, 'cleanIpSpeed'), null, (v) => setState(() => _speed = v)),
              ],
            ],
          ),
          if (_numberError != null) ...[
            const SizedBox(height: 8),
            Text(_numberError!, style: TextStyle(color: scheme.error)),
          ],
          if (_note != null) ...[
            const SizedBox(height: 8),
            Text(_note!),
          ],
          const SizedBox(height: 16),
          Row(children: [
            FilledButton.icon(
              onPressed: _running || (_withServer && _server == null) ? null : _scan,
              icon: _running
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.travel_explore),
              label: Text(_running
                  ? tr(context, _enriching ? 'cleanIpStageEnrich' : (_stage == 1 ? 'cleanIpStage1' : 'cleanIpStage2'),
                      {'done': _done, 'total': _total})
                  : tr(context, 'cleanIpScan')),
            ),
            if (_running)
              TextButton(
                  onPressed: () => setState(() => _cancel = true),
                  child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
          ]),
          if (_running && _live.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(tr(context, 'cleanIpLiveTitle', {'n': _live.length}), style: TextStyle(color: scheme.primary)),
          ],
          if (_found != null && _found!.isEmpty) ...[
            const SizedBox(height: 16),
            Text(tr(context, 'cleanIpNone'), style: TextStyle(color: scheme.error)),
          ],
          if (shown.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              TextButton.icon(
                  onPressed: () => _copy(endpointsText(shown)),
                  icon: const Icon(Icons.copy_all),
                  label: Text(tr(context, 'cleanIpCopyEndpoints'))),
              if (_targetList.isNotEmpty) ...[
                TextButton.icon(
                    onPressed: () => _copy([for (final b in _targetList) ...linksFor(b, _picked.isEmpty ? shown : _pickedResults)].join('\n')),
                    icon: const Icon(Icons.link),
                    label: Text(tr(context, 'cleanIpCopyLinks'))),
                TextButton.icon(
                    onPressed: () => _copy(subscriptionText([for (final b in _targetList) ...linksFor(b, _picked.isEmpty ? shown : _pickedResults)])),
                    icon: const Icon(Icons.rss_feed),
                    label: Text(tr(context, 'cleanIpCopySub'))),
              ],
            ]),
            if (!fixed && widget.state != null && !_running && _servers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(tr(context, 'cleanIpPicked', {'n': _picked.length, 'total': shown.length}),
                      style: TextStyle(color: scheme.primary)),
                ),
                TextButton(
                    onPressed: () => setState(() {
                          if (_picked.length == shown.length) {
                            _picked.clear();
                          } else {
                            _picked..clear()..addAll(shown.map(_key));
                          }
                        }),
                    child: Text(tr(context, _picked.length == shown.length ? 'cleanIpSelectNone' : 'cleanIpSelectAll'))),
              ]),
              Card(
                margin: EdgeInsets.zero,
                child: ExpansionTile(
                  title: Text(tr(context, 'cleanIpPutIn')),
                  subtitle: Text(tr(context, 'cleanIpPicked', {'n': _targetList.length, 'total': _servers.length})),
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final e in _servers)
                            CheckboxListTile(
                              dense: true,
                              value: _targets.contains(e.fields) || (_targets.isEmpty && identical(e.fields, _scanned ?? _chosen)),
                              title: Text(e.name, overflow: TextOverflow.ellipsis),
                              onChanged: (v) => setState(() {
                                // Ticking starts from what was shown ticked (the scanned config).
                                if (_targets.isEmpty) {
                                  final one = _scanned ?? _chosen;
                                  if (one != null) _targets.add(one);
                                }
                                v == true ? _targets.add(e.fields) : _targets.remove(e.fields);
                              }),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                FilledButton.icon(
                    onPressed: _picked.isEmpty || _targetList.isEmpty ? null : () => _addServers(_pickedResults),
                    icon: const Icon(Icons.playlist_add),
                    label: Text(tr(context, 'cleanIpAddPicked', {'n': _picked.length * _targetList.length}))),
                OutlinedButton.icon(
                    onPressed: _picked.length == 1 && _targetList.isNotEmpty ? () => _replaceAddress(_pickedResults.single) : null,
                    icon: const Icon(Icons.swap_horiz),
                    label: Text(tr(context, 'cleanIpReplace'))),
              ]),
              const SizedBox(height: 8),
            ],            for (final r in shown) _row(r, fixed: fixed && !_running),
          ],
        ],
      ),
    );
  }
}
