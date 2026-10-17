# Tern

A fast, keyboard-first Gmail client for macOS. Several accounts, one unified inbox, projects across
accounts, instant local search, and AI triage through your own Codex or Claude Code CLI.

Everything you see is read from a local SQLite database; sync with Gmail happens in the background, so
opening, searching and archiving never wait on the network.

Status: under construction.

## Build

Requires macOS 15 and Xcode 16 or newer.

```
./build.sh --install
```

Try it without a Google account: `swift run tern-seed && open build/Tern.app --args --fake`.
