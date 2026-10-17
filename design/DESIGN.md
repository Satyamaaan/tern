# Tern — visual spec

Direction: **"Cap & Beak"**, named for the Arctic tern's white body, black cap and orange-red beak. Chalk and charcoal
neutrals, one vermilion accent that only ever means *this needs you*, Geist for the interface, and a single
serif voice (Newsreader) in two places: the open thread's subject and empty states. Flat surfaces separated
by hairlines, no shadows at rest. Calm like ChatGPT/Codex and Linear, never the stock macOS look. Research
behind it: `research.md`. Visual reference: `mockup.html` (open it in a browser).

Hard rules
- Never a colored bar down one side of a row, card or callout. Status = a dot or a chip.
- At most three visible actions in any area. Everything else lives in one `…` menu or ⌘K.
- Every action has a shortcut; ⌘K lists each command with its key.
- No spinners or skeletons for cached mail. No white flash when HTML mail loads.
- No pointer cursor, no hover highlight on everything (web tells). Hover only on rows and icon buttons.

## Tokens

| Token | Light | Dark |
| --- | --- | --- |
| `bg` window / list | `#FFFFFF` | `#141414` |
| `sidebar` | `#F6F6F5` | `#0E0E0E` |
| `raised` reader card, popovers | `#FFFFFF` | `#1A1A1A` |
| `hover` | `#F1F1EF` | `#1F1F1F` |
| `selected` | `#EBEBE8` | `#272727` |
| `hairline` | `#E6E6E2` | `#2A2A2A` |
| `hairlineStrong` | `#D6D6D1` | `#3A3A3A` |
| `text1` | `#161616` | `#ECECEA` |
| `text2` | `#5F5F5A` | `#A3A39E` |
| `text3` | `#74746E` | `#85857F` |
| `accent` dots, primary button fill | `#E5461E` | `#FF6B3F` |
| `accentInk` accent text, links | `#C23A16` | `#FF8C66` |
| `accentSoft` chip bg | `#FDECE6` | `#2E1913` |

Primary button: light = `accentInk` fill + white label; dark = `accent` fill + `#141414` label.
On a selected row, `text3` text switches to `text2`.

Chips: 12% tint background, coloured text, radius 6, height 18, Geist 11/16 weight 500.

| Category | Light | Dark |
| --- | --- | --- |
| needs reply | `accentInk` on `accentSoft` | same tokens |
| newsletter | `#6E5BD0` | `#A89BF5` |
| receipt | `#23764A` | `#5CCB91` |
| notification | `#5E6B7A` | `#94A3B3` |
| calendar | `#2F6FD8` | `#78A8FF` |
| promotion | `#96620E` | `#E0B04F` |
| security | `#B4232F` | `#FF8A93` |

Account hues (dot / monogram, muted): `#4F7CAC` `#8A6FB3` `#3E9A86` `#C08A3E` `#B05C7A` `#6B7F4A`.
Project colours (icon tint + 12% tint chip), indices 0–7: `#E5461E` `#2F6FD8` `#23764A` `#8A6FB3` `#C08A3E` `#B05C7A` `#3E9A86` `#5E6B7A`.

Radii: rows and buttons 8 · cards, popovers, reader sheet 12 · pills 999 · chips 6.
Spacing: 4 px grid. Overlay shadow only (palette, menus, toasts): `0 8 30 rgba(0,0,0,.14)` light, `.5` dark.

## Type

Bundled in `Resources/Fonts` (OFL): Geist 400/500/600, Geist Mono 400/500, Newsreader 16pt Regular/Medium/Italic.
Register them at launch with `CTFontManagerRegisterFontsForURL`.

| Use | Font |
| --- | --- |
| UI default | Geist 13/18 |
| Small, meta | Geist 12/16 |
| Row sender | Geist 13/18, 600 unread, 500 read |
| Mailbox title (list header) | Geist 15/20 600 |
| Section caps | Geist 11/14 500, +0.6 tracking, `text3` |
| Times, counts, keycaps | Geist Mono 12/16 (tabular) |
| Open thread subject | **Newsreader Medium 24/30**, −0.2 tracking |
| Empty states, onboarding headline | **Newsreader Italic 22/28** (onboarding 34/40) |
| Reading body (plain text mail) | Geist 14/22, max line 680 |

## Window

- Hidden title bar: `fullSizeContentView`, transparent titlebar, no toolbar. Traffic lights sit at (16, 18) inside
  the sidebar. The whole window background is drawn by us.
- Columns: **sidebar 232** (flat `sidebar`, collapses with ⌘\) · hairline · **list** (min 340, default 420,
  resizable) · hairline · **reader** (flexible, min 420). ⌘⇧\ toggles list-only (reader as full width when
  a thread is open, Esc returns). Minimum window 960×600, default 1320×840.

### Sidebar
Top to bottom, 12 px side padding:
1. 52 px header: traffic lights, then at the right a compose button (pencil icon, 28 px, `c`).
2. **Account switcher**: one pill row showing the current scope ("All accounts" with up to three overlapping
   account dots, or the account's name). Click → menu: All accounts ⌘0, each account ⌘1…⌘9, Add account…,
   Settings… This is the only account UI in the main window.
3. Mailboxes (28 px rows, 8 radius, icon 15 px `text2`, label `text1`, count in mono `text3` at the right):
   Inbox · Needs reply (count in `accentInk`) · Snoozed · Starred · Drafts · Sent · All mail · then a
   `More` row that expands Spam, Trash and the account's Gmail labels (labels only when one account is in scope).
4. `PROJECTS` caps header (a `+` appears on hover). Project rows: icon tinted with the project colour, name,
   unread count. Right-click or `…` on hover: rename, colour, rules, delete.
5. Bottom, pinned: one quiet line of sync status in `text3` 12 px ("Up to date", "Syncing 1,204 of 8,330",
   "Offline — changes will sync", or an `accentInk` "Sign in again" link). Nothing else.

Selected sidebar row: `selected` fill. No icon colour change, no bar.

### List column
- **Header, 52 px**: mailbox title (15/20 600) followed by **the Flock**: one 6 px `accent` dot per thread that
  needs action (inbox unread + needs reply, max 12, then "+n" in mono `text3`). Each triage action lifts a
  dot away (6 px upward drift + fade, 180 ms). At the right: one `…` menu (Mark all read, Select all,
  Density: Auto/Compact/Comfortable, Sort). 
- **Search pill** under the header (32 px, radius 999, `hover` fill, magnifier + "Search" + `/` keycap in mono at
  the right). Focusing it (or `/`) turns the list into search results; Esc restores the mailbox.
- **Split tabs** (Inbox only), 32 px: text tabs `Important 12 · People 8 · Notifications 31 · Newsletters 9 ·
  Other 40` (active = `text1` with a 2 px `text1` underline; others `text2`; counts in mono `text3`). Tab / ⇧Tab
  cycle them. "Important" = people + needs reply + calendar + security; the rest map to categories.
- **Groups**: sticky caps headers 28 px with a hairline below: `NEEDS REPLY` (always first in Inbox/Important) ·
  `TODAY` · `YESTERDAY` · `THIS WEEK` · `EARLIER THIS MONTH` · month names · years. Between the needs-reply group
  and the rest draw the **waterline**: a 1 px dashed hairline (`text3` at 40%) with the count in mono at its
  right end.
- **Rows** (no borders between rows; 6 px inset from the list edges so hover/selection pills float):
  - Auto density: list ≥ 560 px → **one line, 36 px**; narrower → **two lines, 56 px**.
  - Two-line: line 1 = unread dot slot (20 px gutter, 6 px `accent` dot) · sender (600 if unread) · thread count
    in `text3` · (unified view) 8 px account dot · spacer · one chip (project beats category) · paperclip ·
    time in mono `text3`. Line 2 = subject (500, `text1`) — preview (`text3`), one line; if the AI summary exists
    it replaces the preview in `text2` with a tiny ✦ glyph.
  - Sender text for threads: "Maya, Jonas 3"; drafts: "Draft to Maya" in `text2` italic with a pencil glyph.
  - Times: "17m", "3h", "Tue", "Oct 12", "Oct 12 '25".
  - Hover replaces the time with three 24 px icon buttons: Done (archive), Snooze, `…`.
  - Selected: `selected` fill; keyboard focus adds a 1.5 px `accent` ring at 40% opacity.
- Triage: `e` archive → the row collapses (160 ms ease-out) and the next row is selected in the same frame.
  A toast pill bottom-centre: "Archived · Undo  z" (4 s). Multi-select with `x`, ⇧J/⇧K, ⌘A, ⌘/⇧-click.

### Reader
- `raised` surface. Top bar 52 px, right side only: **Done**, **Snooze**, **`…`** (reply all, forward, label,
  project, star, mark unread, mute, spam, trash, print, show original). Left side shows `‹ ›` thread position
  in `text3` ("12 of 48") only on hover.
- Subject in Newsreader Medium 24/30 with 32 px side padding, max width 760. Under it a chip row (category,
  project, Gmail user labels) and, if present, the AI summary: 1–2 lines in `text2` with a ✦ glyph, collapsible.
- Messages: older messages collapsed to one 40 px line (28 px monogram, sender, snippet `text3`, date mono);
  the latest unread (or last) message expanded. Expanded header: monogram, sender 13/600 + address `text3`,
  "to me, Jonas" disclosure, date mono `text3` at right. Body: HTML in a WKWebView (transparent background set
  before first paint; mail styles sanitized; light/dark adaptation for simple mails; remote images blocked
  until "Load images" for that sender). Quoted text collapsed behind a `•••` pill. Attachments: chips
  (file icon, name, size), Space = Quick Look.
- Bottom: a **reply pill** "Reply to Maya…" (36 px, radius 999, `hover` fill) with three ✦ AI quick replies to its
  right on hover. Click / `r` expands the inline composer in place.

### ⌘K palette
Centered 640 px wide, 12 radius, translucent `raised` at 92% with 24 px blur, overlay shadow. 52 px input
(Geist 16) with a scope chip ("All accounts"). Results grouped: Actions (keycaps right-aligned in mono),
Go to, Threads (live search), Projects, Labels, Accounts, Settings. ↑↓ / ⌃N ⌃P, Enter runs, ⌘Enter runs on
all selected threads. Opens in 120 ms (scale .98 → 1 + fade).

### Composer
- Inline reply inside the reader, or a separate floating window for new mail (`c`), 640×560, `raised`, 12 radius.
- Fields as flat rows separated by hairlines: From (only when several accounts; shows the account dot),
  To (pill tokens, autocomplete from contacts), Cc/Bcc revealed with ⌘⇧C/⌘⇧B, Subject (Geist 15/600).
- Body: rich text, minimal formatting popover on selection (bold, italic, link, list, quote). Signature per
  account inserted below.
- Bottom bar: **Send** primary pill (⌘↵) with a chevron for Send later (⌘⇧L), paperclip, ✦ Write with AI (⌘J),
  and discard (trash icon) at the far right. Undo-send toast ("Sending in 5 s · Undo").

### Empty states
Inbox zero: centred tern drawn as a single stroke (900 ms stroke-draw, once), then Newsreader Italic
"Nothing needs you." and one `text3` line ("23 cleared today"). Other mailboxes: one Newsreader Italic line, no
illustration ("No snoozed mail.").

### Settings
Separate window (not a sheet), sidebar of sections: Accounts, AI, Appearance, Shortcuts, Notifications,
Advanced. Flat rows with hairlines, pill controls, no grouped-box chrome.

### Onboarding (first launch)
One window, four steps, Newsreader headline "Mail at the speed you think." 1) Your Google client (paste client
ID + secret, link to the setup guide, "Why?" explains open source). 2) Connect accounts (list + "Add Gmail
account"; each shows sync progress). 3) AI (Codex / Claude Code / Off, each showing "Found, signed in" or
"Not found"). 4) Done. A quiet "Try it with demo mail" link switches to the fake mailbox.

## Motion
Row exit 160 ms ease-out + list collapse 180 ms · pane changes spring (response 0.32, damping 0.86) · palette
120 ms · hover reveal 90 ms · Flock dot lift 180 ms · nothing in the triage path over 200 ms. Reduce Motion:
80 ms crossfades only.

## Keyboard
See `research.md` §E; implement that table. Bare-letter keys are inactive while a text field has focus.
`g` chords time out after 1 s and show a small HUD.
