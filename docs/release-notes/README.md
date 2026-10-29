# Release notes

When a version tag (`v1.2.3`) is pushed, the release job of `.github/workflows/build.yml` makes the
release from `docs/release-notes/<tag>.md` (for example `v1.11.0.md`), followed by the download table
in `downloads.html` (`@@TAG@@` is replaced by the tag). A tag with a dash (`v1.12.0-beta.1`) is
published as a pre-release and never as the latest one. Without a notes file for the tag, GitHub's
own generated notes are used.

So a release is: bump `version:` in `pubspec.yaml`, add `docs/release-notes/<tag>.md`, commit, then push
the commit and the tag.