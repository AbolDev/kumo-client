import 'package:flutter/material.dart';

import '../l10n/extra.dart';
import '../l10n/strings.dart';

/// Asks for one line of text (a password, a port, a number) in a dialog that says what it is for: an
/// icon, a title, a sentence of explanation, a labelled field and the way to confirm.
///
/// [check] is asked when the user confirms: it returns the text of a problem (shown under the field,
/// and the dialog stays open) or null when the answer is fine. It may take a while (a password that
/// is tried on a file): the button shows that it is working. The result is what was typed, or null
/// when the dialog was cancelled.
Future<String?> showPrompt(
  BuildContext context, {
  required String title,
  required String label,
  IconData? icon,
  String? message,
  String? hint,
  String? helper,
  String initial = '',
  bool secret = false,
  TextInputType? keyboard,
  String? confirm,
  Future<String?> Function(String value)? check,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PromptDialog(
      title: title,
      label: label,
      icon: icon,
      message: message,
      hint: hint,
      helper: helper,
      initial: initial,
      secret: secret,
      keyboard: keyboard,
      confirm: confirm,
      check: check,
    ),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.label,
    this.icon,
    this.message,
    this.hint,
    this.helper,
    required this.initial,
    required this.secret,
    this.keyboard,
    this.confirm,
    this.check,
  });

  final String title, label, initial;
  final IconData? icon;
  final String? message, hint, helper, confirm;
  final bool secret;
  final TextInputType? keyboard;
  final Future<String?> Function(String value)? check;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
  late bool _hidden = widget.secret;
  String? _error;
  bool _working = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_working) return;
    final value = _controller.text;
    final check = widget.check;
    if (check == null) {
      Navigator.pop(context, value);
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final problem = await check(value);
    if (!mounted) return;
    if (problem == null) {
      Navigator.pop(context, value);
    } else {
      setState(() {
        _working = false;
        _error = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: widget.icon == null ? null : Icon(widget.icon, size: 32, color: scheme.primary),
      title: Text(widget.title, textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.message != null) ...[
              Text(widget.message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: _hidden,
              enabled: !_working,
              keyboardType: widget.keyboard,
              textInputAction: TextInputAction.done,
              autocorrect: !widget.secret,
              enableSuggestions: !widget.secret,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.hint,
                helperText: widget.helper,
                helperMaxLines: 2,
                errorText: _error,
                errorMaxLines: 3,
                border: const OutlineInputBorder(),
                suffixIcon: widget.secret
                    ? IconButton(
                        tooltip: tr(context, _hidden ? 'a11yShowPassword' : 'a11yHidePassword'),
                        icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hidden = !_hidden),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actions: [
        TextButton(onPressed: _working ? null : () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(
          onPressed: _working ? null : _submit,
          child: _working
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.confirm ?? t.ok),
        ),
      ],
    );
  }
}
