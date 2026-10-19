# Tern — notes for agents

Tern is a native macOS Gmail client built for speed: several Gmail accounts (personal and Google Workspace),
a unified inbox, cross-account projects, instant local search, AI triage through the user's local Codex or
Claude Code CLI, and a modern, keyboard-first UI that does not look like a stock Mac app. It will be open
source.

## The one rule behind the speed

The UI never waits on the network. Every screen reads the local SQLite database (`TernCore`). Sync fills
the database in the background. User actions (archive, label, read, snooze…) change the database at once
through `MailStore.perform`, which also queues a `PendingOp`; the sync engine sends it to Gmail later.

Speed budget, measured on the 50,000-message fake mailbox:

| What | Budget |
| --- | --- |
| Launch to a filled inbox | < 300 ms |
| Open the next thread (j/k) | < 50 ms |
| Search results per keystroke | < 30 ms |
| Archive, label, read | no network wait; next row selected in the same frame |

## Layout

```
Sources/TernCore      models, schema/migrations, MailStore (reads, sync writes, actions + undo), search, fake mailbox
Sources/TernSync      GmailAPI.swift (contract) · Google/ (OAuth, HTTP client, MIME) · Engine/ (sync, op queue)
Sources/TernAI        AI providers (codex / claude CLI), classifier, summaries, reply drafts, project rules
Sources/Tern          the app (SwiftUI + AppKit)
Sources/tern-seed     writes the fake mailbox: swift run tern-seed [--messages N] [--out PATH]
Tests/…               swift-testing (`import Testing`)
design/               research and the visual spec (DESIGN.md)
```

## Contracts (change only with a note in your final report)

- `TernCore/Models.swift` — records. Dates are seconds since 1970 (see `TernRecord`).
- `MailStore` — the only code that writes messages, threads, `thread_label` and the search index.
  `MailThread` rows are derived; never write them yourself, call `refreshThreads`. Sync code that needs
  its own transaction uses the `static func …(_ db: Database, …)` variants. Each thread's Gmail tab is derived
  too (`MailThread.gmailTab`, copied to its `thread_label` rows for the inbox tab indexes): the category label
  of its newest message from someone else (`InboxTab.gmailTab`); threads without one fall back to
  `thread_ai.category` (`InboxTab(fallback:)`, unclassified → Primary). Move to tab is `MailAction.moveToTab`.
- `MailStore.perform(_:on:)` / `undo(_:)` — optimistic actions. Each writes one `PendingOp` per account
  with a `LabelOpPayload` of exact per-message label changes. Move to tab also records what it asks of Gmail
  (`LabelChange.intentAdd`/`intentRemove`: every other category comes off): that is what is sent and what sync
  replays over Gmail's newer labels. Its undo is a move back, not a reverse: each message to the category it had
  when the user acted (none: all off), with the same intent, whatever Gmail filed it under meanwhile.
- `Mailbox` / `ThreadRow` / `ThreadDetail` / `SidebarCounts` — what the UI reads. Scope counts
  (`fetchScopeCounts`) are a pass over the scope's whole inbox, so they are only ever read off the main thread;
  the tab bar's Gmail tabs come from a bounded probe (`fetchTabsWithMail`) when the scope is set.
- `SearchService.search(_:accountId:limit:) -> [ThreadRow]`.
- `TernSync/GmailAPI.swift` — protocol + DTOs mirroring Gmail API v1 JSON. The engine is tested against an
  in-memory fake implementation; the app uses the HTTP client.
- `TernAI/AIProvider.swift` — CLI-backed model access.

Schema changes: add a new migration at the end of `Schema.register` (one line per migration, name it
`<lane>-<n>`, e.g. `reader-1`). Never edit a shipped migration.

## Google sign-in (open source)

Every user brings their own Google Cloud OAuth client (type "Desktop app"), entered in onboarding and
stored in the Keychain. Flow: installed-app OAuth with PKCE and a loopback redirect
(`http://127.0.0.1:<random port>`). Scopes: `https://www.googleapis.com/auth/gmail.modify`, `openid`,
`email`, `profile`. Never commit a client id, secret, token, or anything from `.env`.

## Running

```
swift build                     # everything
swift test                      # all tests (keep them green)
swift run tern-seed             # (re)writes ~/Library/Application Support/Tern/Tern-Fake.sqlite
./build.sh --debug              # build/Tern.app
open build/Tern.app --args --fake   # run against the fake mailbox (also TERN_FAKE=1)
scripts/release.sh              # notarized DMG + signed update zip + appcast for the version in version.env
scripts/publish.sh <version>    # uploads them to dhruvalgolakiya/tern-releases (only when asked)
```

Updates: Sparkle 2 with Tern's own window (`Sources/Tern/Updates`). Only release builds (`TERN_RELEASE=1`, set by
release.sh) get the feed URL and public key in Info.plist; dev builds, `--check`, `--snapshot` and tests never start
the updater or the move-to-Applications prompt (`Sources/Tern/Install`). Raise `TERN_BUILD` in version.env every
release. The EdDSA private key is a file outside the repo (see release.sh); never commit or print it.

UI work should run against the fake mailbox. Don't drive the UI with osascript clicks or keystrokes while
the user is at the Mac; render views offscreen (NSHostingView + cacheDisplay) to check them.

## UI rules

- Modern and calm, not the generic macOS look. Spec: `design/DESIGN.md`.
- Never a colored bar down one side of a card, row or callout. Status goes in a dot or badge.
- Few visible actions at once. Group actions into one menu or the ⌘K palette; secondary controls appear on
  hover. Everything has a keyboard shortcut.
- Lists must stay smooth with 50k threads: AppKit `NSTableView` (cell reuse, fixed row height) for the
  message list; SwiftUI elsewhere.
- Settings is a page of the main window (`Settings/SettingsPage.swift`, `AppModel.openSettings`), never a
  separate window or sheet. Every user-facing preference belongs there: add new ones to `SettingsItem`
  (`Settings/SettingsCatalog.swift`) so they show in their section and in settings search. Interface
  preferences live in `Preferences` (UserDefaults), mail ones shared with other lanes in the database
  `setting` table.

## Keyboard

- `CommandRegistry` is the one list behind the menu bar, ⌘K, the `?` sheet, tooltips and `KeyRouter`. A
  command's keys are its built-in ones with the user's overrides on top (`ShortcutOverrides`, UserDefaults,
  only the deltas, keyed by command id). Show a shortcut with `registry.hint(title, id)` or
  `command.shortcutText`, never as a literal string, so edits show everywhere at once.
- Bare keys (no ⌘ or ⌃) run through `KeyRouter` and only outside text fields; `BareKeySafeMenu` never fires them
  as menu key equivalents. A key the router handles goes no further (its monitor returns nil); while typing, keys
  take their normal way to the text view, so input methods, dead keys and Press and Hold work. `--check` types
  into the fields through the real event path (`SelfCheck+Typing`, `PostedKeys`); debug builds have `--typing` for
  more fields, speeds and a trace of every dispatch (`TypingCheck`). ⌘ keys fire from the menu bar, which is
  rebuilt when shortcuts change. While a text field has the keyboard the menu bar also leaves alone the ⌘/⌃ keys
  of commands that aren't `isTextSafe` (`registry.leavesToText`), so they keep their text meaning. Commands aren't
  text-safe unless they set `isTextSafe: true`: ⌘K, new mail, Settings, find, print, New Project, ⌘0–⌘9, view and
  appearance, and the app's own items. Don't add one that acts on mail or rebuilds the tabs or the list (Inbox
  Tabs isn't text-safe).
- A command that only makes sense in one place sets `yieldsToReader` (list) or `readerOnly`, so it can share a
  bare key with a command of the other scope (`ShortcutRules.canShare`); ⌘/⌃ keys are never shared. Reserved keys
  (macOS, fixed menu items, text-editing Control keys) and locked commands are in `ShortcutRules`. Saved overrides
  are validated when the registry starts (`CommandRegistry.validated`) and saved again without what can't apply.
  Launch reads no file for this: the Control keys of the system's and the user's key bindings files
  (`KeyBindingFiles`) are read once in the background after the window is up (and when the recorder starts), and
  `CommandRegistry.loadKeyBindings` then cleans the saved overrides again.
- A setting that changes how the list is read under the open thread (Inbox Tabs) reloads with
  `reloadList(keepingPlace: true)`, which keeps the cursor, the selection and the open thread.
- The reader page runs Next/Previous Message, Open and Quick Look itself by action name; `KeyRouter.pageKeyMap`
  sends their current keys to `reader.js` (`ReaderWebEngine.keyActions`). Don't hard-code keys in the page.
- While the settings page is open, only `Command.availableInSettings` commands run (`registry.canRun`), and the
  palette lists no threads, projects, labels or accounts.

## Code

- Swift 6 toolchain, Swift 5 language mode, macOS 15+. No new package dependencies without saying why in
  your report; prefer Apple frameworks.
- Keep database writes off the main thread. Reads for one screen are fine on main if they are indexed
  and bounded (`LIMIT`).
- Match the surrounding style: small files by feature, doc comments on public API, no commented-out code.
- Commit on your own branch with clear messages. No `Co-Authored-By` or other AI attribution lines.
  Never push, open PRs, or post anywhere.
