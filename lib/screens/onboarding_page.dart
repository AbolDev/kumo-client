import 'package:flutter/material.dart';

import '../core/net_options.dart' show bypassCountries;
import '../core/platform.dart';
import '../l10n/extra.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';

/// The guide shown once on the first start: what Kumo is, why Android asks for the VPN
/// permission, the language, and the country (kept for later; it changes nothing by itself).
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.state});

  final AppState state;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _controller = PageController();
  var _page = 0;
  var _country = '';

  // The permission page only makes sense on Android.
  int get _pages => isDesktop ? 3 : 4;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish() => widget.state.finishOnboarding(
      language: widget.state.languageCode, country: _country);

  void _next() {
    if (_page >= _pages - 1) {
      _finish();
    } else {
      _controller.nextPage(
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  Widget _slide(IconData icon, String title, String text, [Widget? extra]) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          Text(title,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          if (extra != null) ...[const SizedBox(height: 16), Flexible(child: extra)],
        ],
      ),
    );
  }

  Widget _languages() => ListView(
        shrinkWrap: true,
        children: [
          for (final e in S.languageNames.entries)
            RadioListTile<String>(
              value: e.key,
              groupValue: widget.state.languageCode,
              title: Text(e.value),
              onChanged: (v) => widget.state.setLanguage(v),
            ),
        ],
      );

  Widget _countries() => ListView(
        shrinkWrap: true,
        children: [
          RadioListTile<String>(
            value: '',
            groupValue: _country,
            title: Text(tr(context, 'onbNoCountry')),
            onChanged: (v) => setState(() => _country = v ?? ''),
          ),
          for (final e in bypassCountries.entries)
            RadioListTile<String>(
              value: e.key,
              groupValue: _country,
              title: Text(e.value),
              onChanged: (v) => setState(() => _country = v ?? ''),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final last = _page >= _pages - 1;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Expanded(
                  child: PageView(
                    controller: _controller,
                    onPageChanged: (i) => setState(() => _page = i),
                    children: [
                      _slide(Icons.cloud_outlined, tr(context, 'onbWelcomeTitle'),
                          tr(context, 'onbWelcomeText')),
                      if (!isDesktop)
                        _slide(Icons.vpn_key_outlined, tr(context, 'onbVpnTitle'),
                            tr(context, 'onbVpnText')),
                      _slide(Icons.language, tr(context, 'onbLangTitle'), '',
                          _languages()),
                      _slide(Icons.public, tr(context, 'onbCountryTitle'),
                          tr(context, 'onbCountryText'), _countries()),
                    ],
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _pages; i++)
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == _page
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      TextButton(
                          onPressed: _finish, child: Text(tr(context, 'onbSkip'))),
                      const Spacer(),
                      FilledButton(
                        autofocus: true,
                        onPressed: _next,
                        child: Text(tr(context, last ? 'onbStart' : 'onbNext')),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
