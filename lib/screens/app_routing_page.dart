import 'dart:io' show Platform;

import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/net_options.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';

/// Chooses which apps use the VPN: all, only the chosen ones, or all but the chosen ones.
class AppRoutingPage extends StatefulWidget {
  const AppRoutingPage({super.key, required this.state});

  final AppState state;

  @override
  State<AppRoutingPage> createState() => _AppRoutingPageState();
}

class _AppRoutingPageState extends State<AppRoutingPage> {
  List<AppEntry>? _apps;
  final _search = TextEditingController();
  final _custom = TextEditingController();
  var _changed = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    VpnChannel.listApps().then((l) {
      if (mounted) setState(() => _apps = l);
    }).catchError((_) {
      if (mounted) setState(() => _apps = const []);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _custom.dispose();
    // A running connection picks the change up once, when the user leaves.
    if (_changed) state.reconnectIfConnected();
    super.dispose();
  }

  void _toggle(String id, bool on) {
    _changed = true;
    state.updateNet((o) {
      final set = o.apps.toSet();
      on ? set.add(id) : set.remove(id);
      o.apps = set.toList();
    }, reconnect: false);
  }

  /// Windows: adds programs by their file (picked or dropped); the process name is the file name.
  void _addFiles(Iterable<String> paths) {
    for (final p in paths) {
      final name = p.split(RegExp(r'[\\\\/]')).last.trim();
      if (name.isNotEmpty) _toggle(name, true);
    }
  }

  Future<void> _pickProgram() async {
    final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['exe'], allowMultiple: true);
    if (picked != null) _addFiles(picked.paths.whereType<String>());
  }

  @override
  Widget build(BuildContext context) {
    final o = state.net;
    final q = _search.text.trim().toLowerCase();
    final selected = o.apps.toSet();
    // Chosen apps that are not in the list (a program that is not running) stay visible.
    final known = {for (final a in _apps ?? const <AppEntry>[]) a.id};
    final all = [
      for (final id in o.apps)
        if (!known.contains(id)) AppEntry(id, id),
      ...?_apps,
    ].where((a) => q.isEmpty ||
        a.label.toLowerCase().contains(q) ||
        a.id.toLowerCase().contains(q));
    final modes = {
      AppMode.all: tr(context, 'appModeAll'),
      AppMode.only: tr(context, 'appModeOnly'),
      AppMode.except: tr(context, 'appModeExcept'),
    };
    final page = Scaffold(
      appBar: AppBar(title: Text(tr(context, 'appRouting'))),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => Column(
          children: [
            for (final e in modes.entries)
              RadioListTile<AppMode>(
                value: e.key,
                groupValue: o.appMode,
                onChanged: (m) {
                  _changed = true;
                  state.updateNet((o) => o.appMode = m!, reconnect: false);
                },
                title: Text(e.value),
                dense: true,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(tr(context, 'appRoutingTun'),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  labelText: tr(context, 'searchApps'),
                  suffixText: tr(context, 'selectedApps', {'n': selected.length}),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            if (Platform.isWindows)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: TextField(
                  controller: _custom,
                  onSubmitted: (v) {
                    final name = v.trim();
                    if (name.isNotEmpty) _toggle(name, true);
                    _custom.clear();
                  },
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.add),
                    labelText: tr(context, 'addProcess'),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: tr(context, 'pickProgram'),
                      icon: const Icon(Icons.folder_open),
                      onPressed: _pickProgram,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _apps == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        for (final a in all)
                          CheckboxListTile(
                            secondary: Platform.isWindows
                                ? const Icon(Icons.apps)
                                : _AppIcon(id: a.id),
                            value: selected.contains(a.id),
                            onChanged: (v) => _toggle(a.id, v ?? false),
                            title: Text(a.label),
                            subtitle: a.label == a.id ? null : Text(a.id),
                            dense: true,
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
    if (!Platform.isWindows) return page;
    return DropTarget(
      onDragDone: (d) => _addFiles(d.files.map((f) => f.path)),
      child: page,
    );
  }
}

/// The launcher icon of an installed app, fetched once per app.
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.id});

  final String id;

  static final _cache = <String, Future<Uint8List?>>{};

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: FutureBuilder<Uint8List?>(
        future: _cache.putIfAbsent(id, () => VpnChannel.appIcon(id)),
        builder: (context, snap) => snap.data == null
            ? const Icon(Icons.android)
            : Image.memory(snap.data!, gaplessPlayback: true),
      ),
    );
  }
}
