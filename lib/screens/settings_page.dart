import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/build_flavor.dart';
import '../core/backup.dart';
import '../core/win_autostart.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/latency_tester.dart';
import '../core/net_options.dart' show certStores, logLevels;
import '../core/platform.dart';
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
import 'warp_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _refresh = ValueNotifier<int>(0);

  AppState get state => widget.state;

  @override
  void dispose() {
    _refresh.dispose();
    super.dispose();
  }

  /// Edits the page used by the real delay test. Any answer counts as a reply, so the status
  /// code does not matter; a link is required.
  Future<void> _editDelayUrl(S t) async {
    final controller = TextEditingController(text: state.delayUrl);
    String? error;
    final saved = await showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setLocal) {
          void submit() {
            final v = controller.text.trim();
            final uri = Uri.tryParse(v);
            final ok = (v.startsWith('http://') || v.startsWith('https://')) &&
                uri != null &&
                uri.host.isNotEmpty;
            if (ok) {
              Navigator.pop(dialog, v);
            } else {
              setLocal(() => error = t.invalidUrl);
            }
          }

          return AlertDialog(
            title: Text(t.delayUrlTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => submit(),
                  decoration: InputDecoration(
                      border: const OutlineInputBorder(), errorText: error),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    icon: const Icon(Icons.restart_alt),
                    label: Text(t.resetDefault),
                    onPressed: () => controller.text = defaultDelayUrl,
                  ),
                ),
                Text(tr(context, 'delayUrlNote'),
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog), child: Text(t.cancel)),
              FilledButton(onPressed: submit, child: Text(t.save)),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (saved != null) {
      state.setDelayUrl(saved);
      _refresh.value++;
    }
  }

  Future<String?> _password(String title, {String? hint}) async {
    final c = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
              controller: c,
              obscureText: true,
              autofocus: true,
              onSubmitted: (v) => Navigator.pop(dialog, v),
              decoration: const InputDecoration(border: OutlineInputBorder())),
          if (hint != null) ...[
            const SizedBox(height: 12),
            Text(hint, style: Theme.of(dialog).textTheme.bodySmall),
          ],
        ]),
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

  /// Runs [job] behind a spinner that blocks the screen until it is done.
  Future<T> _working<T>(Future<T> Function() job) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
    );
    try {
      return await job();
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _export() async {
    final password =
        await _password(tr(context, 'backupPassword'), hint: tr(context, 'backupNoPasswordWarn'));
    if (password == null) return;
    final text = await _working(() => state.exportBackup(password));
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
      if (!mounted) return;
      final p = await _password(tr(context, 'backupPasswordNeeded'));
      if (p == null) return;
      password = p;
    }
    // Working out the key takes a few seconds: a spinner shows that the app has not stopped.
    final ok = await _working(() => state.importBackup(text, password));
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
      isDesktop ? tr(context, 'languageDevice') : t.languageSystem;

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
  // The colours are read inside a Builder so the card follows a theme change (the theme fades
  // over a few frames, and the State's own context would keep the first of them).
  Widget _group(List<Widget> children) => Builder(builder: (context) {
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
      });

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

  Widget _tile(List<int> path, _Section s) => Builder(builder: (tileContext) {
        final scheme = Theme.of(tileContext).colorScheme;
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
            tileContext,
            MaterialPageRoute<void>(
              // The page is built again on every change (state, theme, language), so the title,
              // the switches and the colours all follow it.
              builder: (_) => ListenableBuilder(
                listenable: Listenable.merge([state, _refresh]),
                builder: (context, _) {
                  final cur = _resolve(context, path);
                  return Scaffold(
                    appBar: AppBar(title: Text(cur.title)),
                    body: _page([
                      if (cur.children.isNotEmpty) _group(cur.children),
                      if (cur.children.isNotEmpty && cur.subs.isNotEmpty)
                        const SizedBox(height: 12),
                      if (cur.subs.isNotEmpty)
                        _group([
                          for (final (i, sub) in cur.subs.indexed)
                            _tile([...path, i], sub),
                        ]),
                    ]),
                  );
                },
              ),
            ),
          ),
        );
      });
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
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text(tr(context, 'defaultInterval')),
                subtitle: Text(tr(context, 'defaultIntervalDesc')),
                trailing: Text(tr(context, 'hoursShort').replaceAll('{n}', '${state.subInterval}')),
                onTap: () async {
                  final v = await pickOption<int>(
                      context, tr(context, 'defaultInterval'), state.subInterval, {
                    for (final h in {1, 2, 3, 6, 12, 24, 48, 72, 168, state.subInterval}.toList()..sort())
                      h: tr(context, 'hoursShort').replaceAll('{n}', '$h'),
                  });
                  if (v != null) state.setSubInterval(v);
                },
              ),
              _switch('measurePing', state.measurePing, tr(context, 'measurePing'),
                  tr(context, 'measurePingDesc')),
              _switch('usageAlerts', state.usageAlerts, tr(context, 'usageAlerts'),
                  tr(context, 'usageAlertsDesc')),
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
              if (Platform.isAndroid)
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
            if (isDesktop)
              _section(Icons.desktop_windows, tr(context, Platform.isWindows ? 'windows' : 'desktop'), [
                SwitchListTile(
                  value: state.net.minimizeToTray,
                  onChanged: (v) =>
                      state.updateNet((o) => o.minimizeToTray = v, reconnect: false),
                  title: Text(tr(context, 'minimizeToTray')),
                ),
                SwitchListTile(
                  value: state.net.startWithWindows,
                  onChanged: (v) async {
                    // The switch follows what really happened, not what was asked.
                    final done = await WinAutostart.set(v);
                    if (!done && v) {
                      if (context.mounted) toast(context, tr(context, 'autostartUnsafe'));
                      return;
                    }
                    await state.updateNet((o) => o.startWithWindows = v, reconnect: false);
                  },
                  title: Text(tr(context, Platform.isWindows ? 'startWithWindows' : 'startWithSystem')),
                  subtitle: Text(tr(context, Platform.isWindows ? 'startWithWindowsDesc' : 'startWithSystemDesc')),
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
              if (Platform.isAndroid)
                _switch('idleNotification', state.idleNotification,
                    tr(context, 'notifIdle'), tr(context, 'notifIdleDesc')),
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
            _section(Icons.cloud_outlined, tr(context, 'warpTitle'), [
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: Text(tr(context, 'warpTitle')),
                subtitle: Text(state.warp.account == null
                    ? tr(context, 'warpNotSetUp')
                    : tr(context, 'warpMethod', {
                        'method': state.warp.currentMethod ?? '',
                        'address': state.warp.currentAddress ?? '',
                      })),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => WarpPage(state: state)),
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
                  leading: Icon(fdroidBuild ? Icons.info_outline : Icons.system_update),
                  title: Text(fdroidBuild ? 'Kumo' : tr(context, 'checkUpdate')),
                  subtitle: Text(tr(context, 'currentVersion', {'v': snap.data?.version ?? ''})),
                  // The F-Droid build only shows its version: the store updates it.
                  onTap: fdroidBuild ? null : _checkUpdate,
                ),
              ),
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
              ListTile(
                leading: const Icon(Icons.speed),
                title: Text(t.delayUrlTitle),
                subtitle: Text(state.delayUrl,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.ltr),
                onTap: () => _editDelayUrl(t),
              ),
              ListTile(
                leading: const Icon(Icons.memory),
                title: Text(tr(context, 'coreChoice')),
                subtitle: Text(tr(context, 'coreChoiceDesc')),
                trailing: Text(state.net.core == 'xray' ? 'Xray' : 'sing-box'),
                onTap: () async {
                  final v = await pickOption<String>(
                      context, tr(context, 'coreChoice'), state.net.core,
                      {'singbox': 'sing-box', 'xray': 'Xray'});
                  if (v != null) await state.updateNet((o) => o.core = v);
                },
              ),
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: Text(tr(context, 'certStore')),
                subtitle: Text(tr(context, 'certStoreDesc')),
                trailing: Text(tr(context, 'store_${state.net.certStore}')),
                onTap: () async {
                  final v = await pickOption<String>(
                      context, tr(context, 'certStore'), state.net.certStore, {
                    for (final s in certStores) s: tr(context, 'store_$s'),
                  });
                  if (v != null) await state.updateNet((o) => o.certStore = v);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.schedule),
                value: state.net.ntp,
                onChanged: (v) => state.updateNet((o) => o.ntp = v),
                title: Text(tr(context, 'ntp')),
                subtitle: Text(tr(context, 'ntpDesc')),
              ),
              ListTile(
                leading: const Icon(Icons.data_object),
                title: Text(tr(context, 'extraSingbox')),
                subtitle: Text(tr(context, 'extraSingboxDesc')),
                trailing: state.net.extraSingbox.isEmpty ? null : const Icon(Icons.check),
                onTap: () async {
                  final v = await editJson(context, tr(context, 'extraSingbox'),
                      tr(context, 'extraSingboxDesc'), state.net.extraSingbox);
                  if (v != null) await state.updateNet((o) => o.extraSingbox = v);
                },
              ),
              ListTile(
                leading: const Icon(Icons.data_object),
                title: Text(tr(context, 'extraXray')),
                subtitle: Text(tr(context, 'extraXrayDesc')),
                trailing: state.net.extraXray.isEmpty ? null : const Icon(Icons.check),
                onTap: () async {
                  final v = await editJson(context, tr(context, 'extraXray'),
                      tr(context, 'extraXrayDesc'), state.net.extraXray);
                  if (v != null) await state.updateNet((o) => o.extraXray = v);
                },
              ),
              ListTile(
                leading: const Icon(Icons.receipt_long),
                title: Text(tr(context, 'logLevel')),
                subtitle: Text(tr(context, 'logLevelDesc')),
                trailing: Text(state.net.logLevel),
                onTap: () => _choose<String>(
                  tr(context, 'logLevel'),
                  state.net.logLevel,
                  {for (final l in logLevels) l: l},
                  (v) => state.updateNet((o) => o.logLevel = v, reconnect: false),
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
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SearchBar(
              hintText: tr(context, 'settingsSearch'),
              leading: const Icon(Icons.search),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: (v) => setState(() {
                _query = v.trim().toLowerCase();
                if (_query.isEmpty) _otherLanguages = null;
              }),
              trailing: [
                if (_query.isNotEmpty)
                  IconButton(
                    tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _query = '';
                      _otherLanguages = null;
                    }),
                  ),
              ],
            ),
          ),
          if (_query.isEmpty)
            _group([for (final (i, s) in _sections(context).indexed) _tile([i], s)])
          else
            ..._results(context),
        ]),
      ),
    );
  }

  String _query = '';

  /// The sections in every language, kept while a search is going on.
  List<List<_Section>>? _otherLanguages;

  /// The words a settings row shows (title and description), lower case.
  String _words(Widget w) {
    String text(Widget? t) => t is Text ? (t.data ?? '') : '';
    return switch (w) {
      SwitchListTile() => '${text(w.title)} ${text(w.subtitle)}',
      ListTile() => '${text(w.title)} ${text(w.subtitle)}',
      RadioListTile() => text(w.title),
      CheckboxListTile() => '${text(w.title)} ${text(w.subtitle)}',
      _ => '',
    }
        .toLowerCase();
  }

  /// The rows that match the search, each group under the name of its section. A section whose
  /// own name matches shows all of its rows.
  List<Widget> _results(BuildContext context) {
    final out = <Widget>[];
    // The same screen built in every language, so a word typed in any of them finds the row. Built
    // once per search, not at every letter typed.
    var others = _otherLanguages;
    if (others == null) {
      others = <List<_Section>>[];
      try {
        for (final code in S.languageNames.keys) {
          S.forcedLanguage = code;
          others.add(_sections(context));
        }
      } finally {
        S.forcedLanguage = null;
      }
      _otherLanguages = others;
    }
    void walk(List<_Section> sections, List<List<_Section>> others) {
      for (final (i, s) in sections.indexed) {
        final twins = [
          for (final o in others)
            if (i < o.length) o[i],
        ];
        final all = [s.title, for (final t in twins) t.title]
            .any((t) => t.toLowerCase().contains(_query));
        final hits = [
          for (final (j, c) in s.children.indexed)
            if (all ||
                [
                  _words(c),
                  for (final t in twins)
                    if (j < t.children.length) _words(t.children[j]),
                ].any((w) => w.contains(_query)))
              c,
        ];
        if (hits.isNotEmpty) {
          out
            ..add(Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
              child: Text(s.title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary)),
            ))
            ..add(_group(hits));
        }
        walk(s.subs, [for (final t in twins) t.subs]);
      }
    }

    walk(_sections(context), others);
    if (out.isEmpty) {
      out.add(Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(tr(context, 'settingsNoMatch'))),
      ));
    }
    return out;
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
