import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/backup.dart';
import '../core/win_autostart.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/latency_tester.dart';
import '../core/vpn_channel.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../l10n/extra.dart';
import 'connections_page.dart';
import 'logs_page.dart';
import 'network_settings.dart';
import 'share_sheet.dart';
import 'update_dialog.dart';
import 'usage_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _url = TextEditingController(text: widget.state.delayUrl);
  String? _urlError;
  final _refresh = ValueNotifier<int>(0);

  AppState get state => widget.state;

  @override
  void dispose() {
    _url.dispose();
    _refresh.dispose();
    super.dispose();
  }

  void _saveUrl(S t) {
    final v = _url.text.trim();
    final ok = v.startsWith('http://') || v.startsWith('https://');
    setState(() => _urlError = ok ? null : t.invalidUrl);
    _refresh.value++;
    if (ok) state.setDelayUrl(v);
  }

  Future<String?> _password(String title) async {
    final c = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: c,
            obscureText: true,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(dialog, v),
            decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('✕')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, c.text), child: const Text('OK')),
        ],
      ),
    );
    c.dispose();
    return r;
  }

  Future<void> _export() async {
    final password = await _password(tr(context, 'backupPassword'));
    if (password == null) return;
    final text = await state.exportBackup(password);
    final bytes = Uint8List.fromList(utf8.encode(text));
    final path = await FilePicker.platform.saveFile(
        fileName: 'kumo-backup.json', bytes: bytes, type: FileType.any);
    if (path != null && !Platform.isAndroid) await File(path).writeAsBytes(bytes);
    if (mounted && path != null) toast(context, tr(context, 'backupSaved'));
  }

  Future<void> _import() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    final bytes = picked?.files.single.bytes;
    if (bytes == null) return;
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!isBackup(text)) {
      if (mounted) toast(context, tr(context, 'backupWrongPassword'));
      return;
    }
    var password = '';
    if (backupIsEncrypted(text)) {
      final p = await _password(tr(context, 'backupPasswordNeeded'));
      if (p == null) return;
      password = p;
    }
    final ok = await state.importBackup(text, password);
    if (mounted) {
      toast(context, tr(context, ok ? 'backupRestored' : 'backupWrongPassword'));
    }
  }

  /// Shows only the current choice in the list; tapping it opens the other options.
  Future<void> _choose<T>(String title, T current, Map<T, String> options, void Function(T) pick) async {
    final picked = await showDialog<({T value})>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text(title),
        children: [
          for (final e in options.entries)
            RadioListTile<T>(
              value: e.key,
              groupValue: current,
              title: Text(e.value),
              onChanged: (v) => Navigator.pop(dialog, (value: e.key)),
            ),
        ],
      ),
    );
    if (picked != null) pick(picked.value);
  }

  Future<void> _checkUpdate() => checkAndPrompt(context, silent: false);

  /// On Windows the language follows the PC, not a phone.
  String _systemLanguage(S t) =>
      Platform.isWindows ? tr(context, 'languageDevice') : t.languageSystem;

  Widget _switch(String key, bool value, String title, String desc) =>
      SwitchListTile(
        value: value,
        onChanged: (v) => state.setFlag(key, v),
        title: Text(title),
        subtitle: Text(desc),
      );

  /// A row of the Settings list; tapping it opens the section on its own page.
  _Section _section(IconData icon, String title, List<Widget> children) =>
      _Section(icon, title, children);

  /// The section at [path] (indexes into the list, then into each section's subsections).
  _Section _resolve(BuildContext context, List<int> path) {
    var list = _sections(context);
    late _Section s;
    for (final i in path) {
      s = list[i];
      list = s.subs;
    }
    return s;
  }

  /// Rows of one kind in a single rounded card, with thin lines between them.
  Widget _group(List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Column(children: [
        for (final (i, c) in children.indexed) ...[
          if (i > 0)
            Divider(
                height: 1, indent: 16, endIndent: 16, color: scheme.outlineVariant),
          c,
        ],
      ]),
    );
  }

  /// Keeps the lists a comfortable width on a wide desktop window.
  Widget _page(List<Widget> children) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: children,
          ),
        ),
      );

  Widget _tile(List<int> path, _Section s) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: scheme.primaryContainer,
        child: Icon(s.icon, size: 22, color: scheme.onPrimaryContainer),
      ),
      title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(s.title)),
            // The section is built again on every change, so switches and radios follow the state.
            body: ListenableBuilder(
              listenable: Listenable.merge([state, _refresh]),
              builder: (context, _) {
                final cur = _resolve(context, path);
                return _page([
                  if (cur.children.isNotEmpty) _group(cur.children),
                  if (cur.children.isNotEmpty && cur.subs.isNotEmpty)
                    const SizedBox(height: 12),
                  if (cur.subs.isNotEmpty)
                    _group([
                      for (final (i, sub) in cur.subs.indexed)
                        _tile([...path, i], sub),
                    ]),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }
  List<_Section> _sections(BuildContext context) {
    final t = S.of(context);
    final modes = {
      ThemeMode.system: (t.themeSystem, Icons.brightness_auto),
      ThemeMode.light: (t.themeLight, Icons.light_mode),
      ThemeMode.dark: (t.themeDark, Icons.dark_mode),
    };
    final flat = [
            _section(Icons.rss_feed, t.subSettings, [
              _switch('autoUpdateSubs', state.autoUpdateSubs, t.autoUpdateSubs,
                  t.autoUpdateSubsDesc),
              _switch('updateOnStartup', state.updateOnStartup,
                  t.updateOnStartup, t.updateOnStartupDesc),
              _switch('allowInsecure', state.allowInsecure, t.allowInsecure,
                  t.allowInsecureDesc),
              _switch('showCollector', state.showCollector, t.showCollector,
                  t.showCollectorDesc),
            ]),
            _section(Icons.apps, t.appSettings, [
              _switch('autoConnect', state.autoConnect, t.autoConnect,
                  t.autoConnectDesc),
              _switch('restartOnChange', state.restartOnChange,
                  t.restartOnChange, t.restartOnChangeDesc),
              _switch('confirmDelete', state.confirmDelete, t.confirmDelete,
                  t.confirmDeleteDesc),
              if (!Platform.isWindows)
              ListTile(
                leading: const Icon(Icons.battery_saver),
                title: Text(t.batteryTitle),
                onTap: () async {
                  if (await VpnChannel.batteryUnrestricted()) {
                    if (context.mounted) toast(context, t.batteryDone);
                  } else {
                    await VpnChannel.requestBatteryExemption();
                  }
                },
              ),
            ]),
            ...networkSections(context, state, _section).cast<_Section>(),
            if (Platform.isWindows)
              _section(Icons.desktop_windows, tr(context, 'windows'), [
                SwitchListTile(
                  value: state.net.minimizeToTray,
                  onChanged: (v) =>
                      state.updateNet((o) => o.minimizeToTray = v, reconnect: false),
                  title: Text(tr(context, 'minimizeToTray')),
                ),
                SwitchListTile(
                  value: state.net.startWithWindows,
                  onChanged: (v) {
                    WinAutostart.set(v);
                    state.updateNet((o) => o.startWithWindows = v, reconnect: false);
                  },
                  title: Text(tr(context, 'startWithWindows')),
                  subtitle: Text(tr(context, 'startWithWindowsDesc')),
                ),
              ]),
            _section(Icons.palette_outlined, t.uiSettings, [
              ListTile(
                leading: Icon(modes[state.themeMode]!.$2),
                title: Text(t.uiMode),
                subtitle: Text(modes[state.themeMode]!.$1),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: () => _choose<ThemeMode>(
                  t.uiMode,
                  state.themeMode,
                  {for (final e in modes.entries) e.key: e.value.$1},
                  (m) => state.setThemeMode(m),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(t.language),
                subtitle: Text(
                    {null: _systemLanguage(t), ...S.languageNames}[state.languageCode] ?? ''),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: () => _choose<String?>(
                  t.language,
                  state.languageCode,
                  {null: _systemLanguage(t), ...S.languageNames},
                  state.setLanguage,
                ),
              ),              const Divider(height: 1),
              _switch('showSpeed', state.showSpeed, tr(context, 'notifSpeed'),
                  tr(context, 'notifSpeedDesc')),
              _switch('showVolume', state.showVolume, tr(context, 'notifVolume'),
                  tr(context, 'notifVolumeDesc')),
              _switch('showName', state.showName, tr(context, 'notifName'),
                  tr(context, 'notifNameDesc')),
            ]),
            _section(Icons.monitor_heart_outlined, tr(context, 'liveConnections'), [
              ListTile(
                leading: const Icon(Icons.swap_vert),
                title: Text(tr(context, 'liveConnections')),
                subtitle: Text(tr(context, 'liveConnectionsDesc')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => ConnectionsPage(state: state)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.bar_chart),
                title: Text(tr(context, 'usage')),
                subtitle: Text(tr(context, 'usageDesc')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => UsagePage(state: state)),
                ),
              ),
            ]),
            _section(Icons.backup_outlined, tr(context, 'backup'), [
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: Text(tr(context, 'exportBackup')),
                subtitle: Text(tr(context, 'backupDesc')),
                onTap: _export,
              ),
              ListTile(
                leading: const Icon(Icons.download),
                title: Text(tr(context, 'importBackup')),
                onTap: _import,
              ),
            ]),
            _section(Icons.receipt_long, t.logs, [
              ListTile(
                leading: const Icon(Icons.list_alt),
                title: Text(t.logs),
                subtitle: Text(t.logsDesc),
                trailing: Text('${state.logs.length}'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => LogsPage(state: state)),
                ),
              ),
            ]),
            _section(Icons.info_outline, tr(context, 'about'), [
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snap) => ListTile(
                  leading: const Icon(Icons.system_update),
                  title: Text(tr(context, 'checkUpdate')),
                  subtitle: Text(tr(context, 'currentVersion', {'v': snap.data?.version ?? ''})),
                  onTap: _checkUpdate,
                ),
              ),
              _switch('updatePrerelease', state.updatePrerelease,
                  tr(context, 'prereleaseUpdates'),
                  tr(context, 'prereleaseUpdatesDesc')),
              ListTile(
                leading: const Icon(Icons.code),
                title: Text(tr(context, 'sourceCode')),
                subtitle: const Text('github.com/AbolDev/kumo-client',
                    textDirection: TextDirection.ltr),
                onTap: () => openLink('https://github.com/AbolDev/kumo-client'),
              ),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('GitHub'),
                subtitle: const Text('github.com/AbolDev',
                    textDirection: TextDirection.ltr),
                onTap: () => openLink('https://github.com/AbolDev'),
              ),
            ]),
            _section(Icons.memory, t.coreSettings, [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _url,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => _saveUrl(t),
                  onTapOutside: (_) => _saveUrl(t),
                  decoration: InputDecoration(
                    labelText: t.delayUrlTitle,
                    border: const OutlineInputBorder(),
                    errorText: _urlError,
                    suffixIcon: IconButton(
                      tooltip: t.resetDefault,
                      icon: const Icon(Icons.restart_alt),
                      onPressed: () {
                        _url.text = defaultDelayUrl;
                        _saveUrl(t);
                      },
                    ),
                  ),
                ),
              ),
            ]),
    ];
    return _arrange(flat);
  }

  /// Groups the flat list of sections into the menu: the app, UI and core settings, the backup
  /// and the Windows options sit under App settings; DNS and the advanced options under Network;
  /// the logs under Live connections.
  List<_Section> _arrange(List<_Section> flat) {
    _Section? by(IconData icon) =>
        flat.where((s) => s.icon == icon).firstOrNull;
    _Section with_(_Section? s, List<_Section?> subs) => _Section(
        s!.icon, s.title, s.children,
        subs: [for (final x in subs) if (x != null) x]);
    return [
      by(Icons.rss_feed)!,
      with_(by(Icons.apps), [
        by(Icons.palette_outlined),
        by(Icons.memory),
        by(Icons.desktop_windows),
        by(Icons.backup_outlined),
      ]),
      with_(by(Icons.lan), [by(Icons.dns), by(Icons.tune)]),
      with_(by(Icons.monitor_heart_outlined), [by(Icons.receipt_long)]),
      by(Icons.info_outline)!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.settings)),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => _page([
          _group([for (final (i, s) in _sections(context).indexed) _tile([i], s)]),
        ]),
      ),
    );
  }
}

/// Describes one section; it is shown as a row (see [_SettingsPageState._tile]), never built itself.
class _Section extends StatelessWidget {
  const _Section(this.icon, this.title, this.children, {this.subs = const []});

  final IconData icon;
  final String title;
  final List<Widget> children;
  final List<_Section> subs;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
