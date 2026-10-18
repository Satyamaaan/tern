# Tern

A fast, native Gmail client for macOS. Tern keeps your mail in a local SQLite database, so opening,
moving between, searching and labelling mail never waits on the network. Sync with Gmail runs in the
background.

- **Several accounts in one inbox.** Personal Gmail and Google Workspace side by side, or one at a time.
- **Projects across accounts.** Group conversations by project with rules (sender, domain, label,
  subject) or by hand, whichever account they arrived in.
- **Instant search.** Gmail's search syntax (`from:` `to:` `has:attachment` `before:` `label:` …) over a
  local full-text index, with Gmail's own search for mail that isn't stored yet.
- **Keyboard first.** `j`/`k`, `e`, `#`, `s`, `z` to undo, ⌘K for every command.
- **AI on your own subscription.** Triage, summaries and reply drafts through the Codex CLI or Claude
  Code you already use. No API keys, nothing sent anywhere else.
- **Private by design.** No Tern server. Remote images are blocked until you allow them, and your Google
  client and tokens stay in the macOS Keychain.

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode 16 or later, or the Command Line Tools)
- A Google Cloud OAuth client of type **Desktop app**. Tern ships without one; you create your own in
  about ten minutes: [docs/google-setup.md](docs/google-setup.md).
- Optional, for AI: the `codex` or `claude` CLI, signed in.

## Download

Notarized builds for Apple Silicon Macs are on the [Releases](https://github.com/dhruvalgolakiya/tern-releases/releases)
page: open the disk image and drag Tern to Applications. From 0.2.0 Tern keeps itself up to date: new versions
download in the background and install when Tern restarts (Settings → Advanced → Update automatically). You still
bring your own Google OAuth client (below).

## Build and run

```sh
./build.sh --install          # builds, signs and installs ~/Applications/Tern.app, then opens it
```

On first launch Tern asks for your OAuth client ID and secret (or the JSON file Google gives you),
then signs in each account in your browser.

## Development

```sh
swift build                           # everything
TERN_SKIP_PERF=1 swift test           # all tests
swift run tern-seed                   # writes a 50,000-message fake mailbox
open build/Tern.app --args --fake     # run against it (build with ./build.sh --debug first)
scripts/release.sh                    # notarized DMG, signed update zip and appcast (needs a Developer ID; see the script)
scripts/publish.sh <version>          # uploads them to a GitHub release in dhruvalgolakiya/tern-releases
```

The version lives in `version.env`; raise `TERN_BUILD` by one for every release (Sparkle compares it). Only builds
made by `scripts/release.sh` carry the update feed, so development builds never update themselves.

`CLAUDE.md` describes the architecture and the rules the code follows. The visual spec is
`design/DESIGN.md`.

## Credits

- [Inter](https://github.com/rsms/inter) by Rasmus Andersson and the Inter Project Authors, under the SIL Open Font
  License 1.1 ([Resources/Fonts/OFL-Inter.txt](Resources/Fonts/OFL-Inter.txt)).
- [Hugeicons](https://github.com/hugeicons/hugeicons) free "Stroke Rounded" icons, under the MIT License
  ([Resources/Licenses/Hugeicons-MIT.txt](Resources/Licenses/Hugeicons-MIT.txt)). `scripts/hugeicons.py` turns the
  icons Tern uses into `Sources/Tern/Shared/Hugeicons.swift`.

- [Sparkle](https://sparkle-project.org) for auto-update, under the MIT License
  ([Resources/Licenses/Sparkle-LICENSE.txt](Resources/Licenses/Sparkle-LICENSE.txt)). Tern draws its own update window.
- [dmgbuild](https://github.com/dmgbuild/dmgbuild) (MIT) lays out the disk image at release time; it isn't shipped.

## License

MIT. See [LICENSE](LICENSE).
