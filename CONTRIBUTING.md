# Contributing to Kumo

Thank you for helping. Bug fixes, translations and small improvements are all welcome.

## Before you start

- Look through the [issues](../../issues) first. For a big change, open an issue to talk about it
  before you write the code.
- Keep one change per pull request.

## Building

```
flutter pub get
flutter test
```

See *Build from source* in the README for the Android and Windows cores. Pull requests are built
and tested by GitHub Actions (`.github/workflows/build.yml`); they must pass.

## Code

- Follow the style of the code around your change (naming, comment density).
- Add or update a test for parser and core logic (`test/`).
- New texts need all seven languages: `lib/l10n/` holds `S` (English and Persian), and
  `lib/l10n/extra.dart` plus `extra_langs.dart` hold the others. Add the key to every map.
- Do not add analytics, ads or anything that sends data about the user.

## Commits

Write short, clear commit messages in English that say what changed and why.

## License

By contributing you agree that your work is released under the GPL-3.0-or-later license of the
project.