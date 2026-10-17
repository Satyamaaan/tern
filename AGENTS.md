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
  its own transaction uses the `static func …(_ db: Database, …)` variants.
- `MailStore.perform(_:on:)` / `undo(_:)` — optimistic actions. Each writes one `PendingOp` per account
  with a `LabelOpPayload` of exact per-message label changes.
- `Mailbox` / `ThreadRow` / `ThreadDetail` / `SidebarCounts` — what the UI reads.
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
```

UI work should run against the fake mailbox. Don't drive the UI with osascript clicks or keystrokes while
the user is at the Mac; render views offscreen (NSHostingView + cacheDisplay) to check them.

## UI rules

- Modern and calm, not the generic macOS look. Spec: `design/DESIGN.md`.
- Never a colored bar down one side of a card, row or callout. Status goes in a dot or badge.
- Few visible actions at once. Group actions into one menu or the ⌘K palette; secondary controls appear on
  hover. Everything has a keyboard shortcut.
- Lists must stay smooth with 50k threads: AppKit `NSTableView` (cell reuse, fixed row height) for the
  message list; SwiftUI elsewhere.

## Code

- Swift 6 toolchain, Swift 5 language mode, macOS 15+. No new package dependencies without saying why in
  your report; prefer Apple frameworks.
- Keep database writes off the main thread. Reads for one screen are fine on main if they are indexed
  and bounded (`LIMIT`).
- Match the surrounding style: small files by feature, doc comments on public API, no commented-out code.
- Commit on your own branch with clear messages. No `Co-Authored-By` or other AI attribution lines.
  Never push, open PRs, or post anywhere.
