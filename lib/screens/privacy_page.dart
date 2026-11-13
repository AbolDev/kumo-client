import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';

import '../core/app_icon.dart';
import '../core/vpn_channel.dart';
import '../l10n/extra.dart';
import '../state/app_state.dart';
import '../widgets/hold_to_confirm.dart';

/// Settings > Disguise and erase.
///
/// Disguise (Android): the launcher shows an everyday app's icon and name instead of Kumo's, or no icon at all; the
/// user may also type any name and take the icon of any app on the phone, for a shortcut on the home screen and for
/// the card of the app in the list of recent apps.
///
/// Erase (everywhere): everything the app keeps is deleted. It cannot be done by a tap: the button asks, and the
/// answer is held down for three seconds. The dialled code that erases without asking is off until it is turned on.
class PrivacyPage extends StatefulWidget {
  const PrivacyPage({super.key, required this.state, this.android, this.erase});

  final AppState state;

  /// Whether the disguise is shown (the phone only); the tests set it.
  final bool? android;

  /// What erases (the state's own, unless a test gives another).
  final Future<void> Function()? erase;

  @override
  State<PrivacyPage> createState() => _PrivacyPageState();
}

/// The look of each disguise in the picker: a picture drawn from a symbol and the colour of the real icon.
const _looks = <String, (IconData, Color)>{
  'd_calc': (Icons.calculate, Color(0xFF3B4252)),
  'd_notes': (Icons.sticky_note_2, Color(0xFFF6C945)),
  'd_clock': (Icons.access_time_filled, Color(0xFF3A7BD5)),
  'd_weather': (Icons.wb_sunny, Color(0xFF4FA8E8)),
  'd_calendar': (Icons.calendar_month, Color(0xFFE5484D)),
  'd_files': (Icons.folder, Color(0xFF1E88E5)),
};

class _PrivacyPageState extends State<PrivacyPage> {
  AppState get state => widget.state;
  bool get _android => widget.android ?? Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    state.addListener(_changed);
  }

  @override
  void dispose() {
    state.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _pickLook(String id) async {
    await state.setDisguise(id, name: tr(context, 'disguise_${id.substring(2)}'));
  }

  Future<void> _hide(bool on) async {
    if (!on) {
      await state.setAppIcon(AppIcon.defaultId);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr(d, 'disguiseHideAsk')),
        content: Text(tr(d, 'disguiseHideBody')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(MaterialLocalizations.of(d).cancelButtonLabel)),
          TextButton(
              key: const ValueKey('hide-yes'), onPressed: () => Navigator.pop(d, true), child: Text(tr(d, 'disguiseHideYes'))),
        ],
      ),
    );
    if (ok == true) await state.setDisguise(AppIcon.hidden, name: state.disguiseName);
  }

  Future<void> _custom() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CustomLook(state: state, say: _say),
    );
  }

  Future<void> _panicCode(bool on) async {
    if (!on) {
      state.setPanicCode(false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr(d, 'eraseCodeAsk')),
        content: Text(tr(d, 'eraseCodeBody')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(MaterialLocalizations.of(d).cancelButtonLabel)),
          TextButton(
              key: const ValueKey('code-yes'),
              style: TextButton.styleFrom(foregroundColor: Theme.of(d).colorScheme.error),
              onPressed: () => Navigator.pop(d, true),
              child: Text(tr(d, 'eraseCodeYes'))),
        ],
      ),
    );
    if (ok == true) state.setPanicCode(true);
  }

  Future<void> _askErase() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr(d, 'eraseAsk')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr(d, 'eraseAskBody')),
            const SizedBox(height: 20),
            HoldToConfirm(
              key: const ValueKey('hold-erase'),
              label: tr(d, 'eraseHold'),
              onConfirmed: () => Navigator.pop(d, true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(MaterialLocalizations.of(d).cancelButtonLabel)),
        ],
      ),
    );
    if (ok == true) await (widget.erase ?? state.eraseEverything)();
  }

  Widget _look(String key, Widget picture, String label, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 84,
      child: InkWell(
        key: ValueKey(key),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(children: [
            Container(
              width: 60,
              height: 60,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(width: 2.5, color: selected ? scheme.primary : Colors.transparent),
              ),
              child: picture,
            ),
            const SizedBox(height: 4),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: selected ? FontWeight.w700 : null)),
          ]),
        ),
      ),
    );
  }

  Widget _symbol(IconData icon, Color color) => Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(13)),
        child: Icon(icon, color: Colors.white, size: 28),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final kumoLook = AppIcon.isPicture(state.appIcon) && state.disguiseName.isEmpty;
    final customLook = !AppIcon.disguises.contains(state.appIcon) && !state.iconHidden && state.disguiseName.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'privacyTools'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(tr(context, 'disguiseTitle'), style: text.titleMedium),
          const SizedBox(height: 6),
          if (!_android)
            Text(tr(context, 'disguiseAndroidOnly'), key: const ValueKey('disguise-android-only'), style: text.bodyMedium)
          else ...[
            Text(tr(context, 'disguiseDesc'), style: text.bodyMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                _look('look:kumo', ClipRRect(borderRadius: BorderRadius.circular(13), child: Image.asset(AppIcon.preview(AppIcon.defaultId), width: 50, height: 50)),
                    tr(context, 'disguiseKumo'), kumoLook, () => state.setAppIcon(AppIcon.defaultId)),
                for (final e in _looks.entries)
                  _look('look:${e.key}', _symbol(e.value.$1, e.value.$2), tr(context, 'disguise_${e.key.substring(2)}'),
                      state.appIcon == e.key, () => _pickLook(e.key)),
                _look('look:custom', _symbol(Icons.edit, scheme.secondary), tr(context, 'disguiseCustom'), customLook, _custom),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('hide-switch'),
              contentPadding: EdgeInsets.zero,
              value: state.iconHidden,
              onChanged: _hide,
              title: Text(tr(context, 'disguiseHide')),
              subtitle: Text(tr(context, 'disguiseHideDesc')),
            ),
            const SizedBox(height: 4),
            Text(tr(context, 'disguiseNote'), style: text.bodySmall?.copyWith(color: scheme.outline)),
          ],
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 16),
          Text(tr(context, 'eraseTitle'), style: text.titleMedium),
          const SizedBox(height: 6),
          Text(tr(context, 'eraseDesc'), style: text.bodyMedium),
          if (_android)
            SwitchListTile(
              key: const ValueKey('code-switch'),
              contentPadding: EdgeInsets.zero,
              value: state.panicCode,
              onChanged: _panicCode,
              title: Text(tr(context, 'eraseCode')),
              subtitle: Text(tr(context, 'eraseCodeDesc')),
            ),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            key: const ValueKey('erase-button'),
            style: FilledButton.styleFrom(foregroundColor: scheme.error),
            onPressed: _askErase,
            icon: const Icon(Icons.delete_forever_outlined),
            label: Text(tr(context, 'eraseButton')),
          ),
        ],
      ),
    );
  }
}

/// The sheet of "Your own": a name, and the icon of an app on the phone.
class _CustomLook extends StatefulWidget {
  const _CustomLook({required this.state, required this.say});

  final AppState state;
  final void Function(String text) say;

  @override
  State<_CustomLook> createState() => _CustomLookState();
}

class _CustomLookState extends State<_CustomLook> {
  late final _name = TextEditingController(text: widget.state.disguiseName);
  late final Future<List<AppEntry>> _apps = VpnChannel.listApps();
  String? _app;
  Uint8List? _icon;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _choose(AppEntry app) async {
    final icon = await VpnChannel.appIcon(app.id);
    if (!mounted) return;
    setState(() {
      _app = app.id;
      _icon = icon;
      // The name of the app is offered when none was typed.
      if (_name.text.trim().isEmpty) _name.text = app.label;
    });
  }

  Future<void> _pin() async {
    final ok = await VpnChannel.pinShortcut(_name.text.trim(), _icon);
    widget.say(tr(context, ok ? 'disguisePinned' : 'disguisePinFail'));
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _card() async {
    await widget.state.setDisguise(widget.state.appIcon, name: _name.text.trim(), icon: _icon);
    widget.say(tr(context, 'disguiseCardDone'));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final named = _name.text.trim().isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 12 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr(context, 'disguiseCustomTitle'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(tr(context, 'disguiseCustomDesc'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('custom-name'),
              controller: _name,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: tr(context, 'disguiseName'),
                hintText: tr(context, 'disguiseNameHint'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            Text(_app == null ? tr(context, 'disguiseIconNone') : tr(context, 'disguiseIconFrom'),
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            SizedBox(
              height: 220,
              child: FutureBuilder<List<AppEntry>>(
                future: _apps,
                builder: (context, snap) {
                  final apps = snap.data;
                  if (apps == null) return const Center(child: CircularProgressIndicator());
                  return ListView.builder(
                    itemCount: apps.length,
                    itemBuilder: (_, i) => ListTile(
                      key: ValueKey('app:${apps[i].id}'),
                      dense: true,
                      selected: apps[i].id == _app,
                      leading: _Thumb(id: apps[i].id),
                      title: Text(apps[i].label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => _choose(apps[i]),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('custom-pin'),
              onPressed: named ? _pin : null,
              icon: const Icon(Icons.add_to_home_screen),
              label: Text(tr(context, 'disguisePin')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('custom-card'),
              onPressed: named ? _card : null,
              style: OutlinedButton.styleFrom(foregroundColor: scheme.primary),
              icon: const Icon(Icons.view_carousel_outlined),
              label: Text(tr(context, 'disguiseCard')),
            ),
          ],
        ),
      ),
    );
  }
}

/// The small icon of an installed app in the list.
class _Thumb extends StatefulWidget {
  const _Thumb({required this.id});

  final String id;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  late final Future<Uint8List?> _png = VpnChannel.appIcon(widget.id);

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 36,
        height: 36,
        child: FutureBuilder<Uint8List?>(
          future: _png,
          builder: (_, snap) => snap.data == null
              ? const Icon(Icons.apps)
              : Image.memory(snap.data!, width: 36, height: 36, filterQuality: FilterQuality.medium),
        ),
      );
}
