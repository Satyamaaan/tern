# Tern — visual spec

Direction: **"Cap & Beak"**, named for the Arctic tern's white body and black cap. Chalk and charcoal
neutrals and **one neutral ink** (near-black in light, near-white in dark) for primary buttons and everything
that means *this needs you*. The interface itself has no hue: colour only appears in data (account dots,
project and category chips, mail content). Geist for the interface, and a single serif voice (Newsreader) in
two places: the open thread's subject and empty states. Flat surfaces separated by hairlines, small 6 px
corners, no shadows at rest. Calm like ChatGPT/Codex, Linear and Vercel, never the stock macOS look. Research
behind it: `research.md`. Visual reference: `mockup.html` (open it in a browser).

Hard rules
- Never a colored bar down one side of a row, card or callout. Status = a dot or a chip.
- No hue in the chrome. "Needs you" reads through ink vs grey, fill vs ring, weight and position, never colour.
- Nothing is a pill. Only avatars, status dots and the Flock are round.
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
| `ink` primary fill, unread / needs-reply dots, Flock, focus ring, links | `#18181B` | `#EDEDEA` |
| `inkHover` primary under the pointer | `#2E2E33` | `#D9D9D5` |
| `inkPressed` primary while pressed | `#45454B` | `#C4C4BF` |
| `inkSoft` needs-reply chip bg | `#E4E4E0` | `#303030` |
| `onInk` label on an `ink` fill | `#FFFFFF` | `#141414` |

On a selected row, `text3` text switches to `text2`. Search matches get an `ink` 13% mark behind the word.
The ✦ AI glyph is `text2`/`text3`, never a colour. Errors are `ink` 500 text (no red); invalid recipients get a
dashed `text2` outline. Destructive confirmations stay in `NSAlert` with the system's destructive button.

Chips: 12% tint background, coloured text, radius 4, height 18, Geist 11/16 weight 500.

| Category | Light | Dark |
| --- | --- | --- |
| needs reply | `ink` on `inkSoft`, with a 5 px `ink` dot before the text | same tokens |
| newsletter | `#6E5BD0` | `#A89BF5` |
| receipt | `#23764A` | `#5CCB91` |
| notification | `#5E6B7A` | `#94A3B3` |
| calendar | `#2F6FD8` | `#78A8FF` |
| promotion | `#96620E` | `#E0B04F` |
| security | `#B4232F` | `#FF8A93` |

Account hues (dot / monogram, muted): `#4F7CAC` `#8A6FB3` `#3E9A86` `#8F7F62` `#B05C7A` `#6B7F4A`.
Project colours (icon tint + 12% tint chip), indices 0–7: Graphite `#6B6B66`, Blue `#2F6FD8`, Green `#23764A`,
Violet `#8A6FB3`, Sand `#8F7F62`, Rose `#B05C7A`, Teal `#3E9A86`, Slate `#5E6B7A`.

Radii (`Theme.Radius`): **chip 4** (chips, recipient tokens, keycaps, count badges, search marks, `•••`) ·
**control 6** (buttons, icon buttons, fields, search, segmented controls, attachment chips) · **row 6** (list,
sidebar, menu and palette rows) · **overlay 8** (toasts, chord HUD, formatting bar) · **card 10** (⌘K,
dropdowns, popovers, composer card, shortcut sheet, rich mail card). Corners use the continuous style.
Spacing: 4 px grid. Overlay shadow only (palette, menus, toasts): `0 8 30 rgba(0,0,0,.14)` light, `.5` dark.
Never a shadow on a button.

## Buttons

One system (`TernButtonStyle`, `IconButtonStyle`, `LinkButtonStyle` in `Shell/Components.swift`):

| | Height | Padding | Label | Rest | Hover | Pressed |
| --- | --- | --- | --- | --- | --- | --- |
| primary | 28 (small 24) | 12 (small 10) | Geist Medium 13 (12), `onInk` | `ink` fill | `inkHover` | `inkPressed` |
| secondary | 28 (small 24) | 12 (small 10) | Geist Medium 13 (12), `text1` | 1 px `hairlineStrong` border | `hover` fill | `selected` fill |
| quiet | 28 (small 24) | 12 (small 10) | Geist Medium 13 (12), `text1` | nothing | `hover` fill | `selected` fill |
| icon | 28 × 28 (24 in rows) | — | 13–15 px glyph, `text2` | nothing | `hover` fill | `selected` fill |
| link | text | — | Geist Medium 12, `ink` | — | underline | 60 % |

All radius 6. Keyboard focus: a 1.5 px `ink` ring at 50 %, 2.5 px outside the control. Disabled: 40 % opacity,
no hover. At most one primary per area. The Send button is one `ink` block split by a 1 px `onInk` 22 % rule
into Send and a send-later chevron; each half steps to `inkHover` / `inkPressed` on its own. Segmented
controls: a 28 pt `selected` track (2 px inset), the chosen segment `raised` with a `hairlineStrong` border,
radius 4 inside 6. Switches are tinted `ink`.

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
2. **Account switcher**: one 32 px field (radius 6, hairline border) showing the current scope ("All accounts" with up to three overlapping
   account dots, or the account's name). Click → menu: All accounts ⌘0, each account ⌘1…⌘9, Add account…,
   Settings… This is the only account UI in the main window.
3. Mailboxes (28 px rows, 6 radius, icon 15 px `text2`, label `text1`, count in mono `text3` at the right):
   Inbox · Needs reply (count in `ink`, mono 500) · Snoozed · Starred · Drafts · Sent · All mail · then a
   `More` row that expands Spam, Trash and the account's Gmail labels (labels only when one account is in scope).
4. `PROJECTS` caps header (a `+` appears on hover). Project rows: icon tinted with the project colour, name,
   unread count. Right-click or `…` on hover: rename, colour, rules, delete.
5. Bottom, pinned: one quiet line of sync status in `text3` 12 px ("Up to date", "Syncing 1,204 of 8,330",
   "Offline — changes will sync", or an `ink` "Sign in again" link). The dot is a hollow `text3` ring when
   up to date, a filled `text3` dot while syncing, a filled `ink` dot when something needs you. Nothing else.

Selected sidebar row: `selected` fill. No icon colour change, no bar.

### List column
- **Header, 52 px**: mailbox title (15/20 600) followed by **the Flock**: one 6 px `ink` dot per thread that
  needs action (inbox unread + needs reply, max 12, then "+n" in mono `text3`). Each triage action lifts a
  dot away (6 px upward drift + fade, 180 ms). At the right: one `…` menu (Mark all read, Select all,
  Density: Auto/Compact/Comfortable, Sort). 
- **Search field** under the header (32 px, radius 6, `hover` fill, a `hairlineStrong` border while focused,
  magnifier + "Search" + `/` keycap in mono at the right). Focusing it (or `/`) turns the list into search results; Esc restores the mailbox.
- **Split tabs** (Inbox only), 32 px: text tabs `Important 12 · People 8 · Notifications 31 · Newsletters 9 ·
  Other 40` (active = `text1` with a 2 px `text1` underline; others `text2`; counts in mono `text3`). Tab / ⇧Tab
  cycle them. "Important" = people + needs reply + calendar + security; the rest map to categories.
- **Groups**: sticky caps headers 28 px with a hairline below: `NEEDS REPLY` (always first in Inbox/Important) ·
  `TODAY` · `YESTERDAY` · `THIS WEEK` · `EARLIER THIS MONTH` · month names · years. Between the needs-reply group
  and the rest draw the **waterline**: a 1 px dashed hairline (`text3` at 40%) with the count in mono at its
  right end.
- **Rows** (no borders between rows; 6 px inset from the list edges so hover/selection fills float; radius 6):
  - Auto density: list ≥ 560 px → **one line, 36 px**; narrower → **two lines, 56 px**.
  - Two-line: line 1 = unread dot slot (20 px gutter, 6 px `ink` dot) · sender (600 if unread) · thread count
    in `text3` · (unified view) 8 px account dot · spacer · one chip (project beats category) · paperclip ·
    time in mono `text3`. Line 2 = subject (500, `text1`) — preview (`text3`), one line; if the AI summary exists
    it replaces the preview in `text2` with a tiny ✦ glyph.
  - Sender text for threads: "Maya, Jonas 3"; drafts: "Draft to Maya" in `text2` italic with a pencil glyph.
  - Times: "17m", "3h", "Tue", "Oct 12", "Oct 12 '25".
  - Hover replaces the time with three 24 px icon buttons: Done (archive), Snooze, `…`.
  - Selected: `selected` fill; keyboard focus adds a 1.5 px `ink` ring at 45% opacity.
- Triage: `e` archive → the row collapses (160 ms ease-out) and the next row is selected in the same frame.
  A toast bottom-centre (36 px, radius 8, `ink` fill, `bg` text): "Archived · Undo  z" (4 s). Multi-select with `x`, ⇧J/⇧K, ⌘A, ⌘/⇧-click.

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
  until "Load images" for that sender). Quoted text collapsed behind a `•••` toggle (radius 4). Attachments: chips
  (file icon, name, size), Space = Quick Look.
- Bottom: a **reply field** "Reply to Maya…" (36 px, radius 6, `hover` fill) with three ✦ AI quick replies
  (secondary buttons) to its right on hover. Click / `r` expands the inline composer in place.

### ⌘K palette
Centered 640 px wide, 10 radius, translucent `raised` at 92% with 24 px blur, overlay shadow. 52 px input
(Geist 16) with a scope chip ("All accounts"). Results grouped: Actions (keycaps right-aligned in mono),
Go to, Threads (live search), Projects, Labels, Accounts, Settings. ↑↓ / ⌃N ⌃P, Enter runs, ⌘Enter runs on
all selected threads. Opens in 120 ms (scale .98 → 1 + fade).

### Composer
- Inline reply inside the reader, or a separate floating window for new mail (`c`), 640×560, `raised`, 10 radius.
- Fields as flat rows separated by hairlines: From (only when several accounts; shows the account dot),
  To (tokens with radius 4, autocomplete from contacts), Cc/Bcc revealed with ⌘⇧C/⌘⇧B, Subject (Geist 15/600).
- Body: rich text, minimal formatting popover on selection (bold, italic, link, list, quote). Signature per
  account inserted below.
- Bottom bar: **Send** primary button (⌘↵) with a chevron for Send later (⌘⇧L), paperclip, ✦ Write with AI (⌘J),
  and discard (trash icon) at the far right. Undo-send toast ("Sending in 5 s · Undo").

### Empty states
Inbox zero: centred tern drawn as a single stroke (900 ms stroke-draw, once), then Newsreader Italic
"Nothing needs you." and one `text3` line ("23 cleared today"). Other mailboxes: one Newsreader Italic line, no
illustration ("No snoozed mail.").

### Settings
Separate window (not a sheet), sidebar of sections: Accounts, AI, Appearance, Shortcuts, Notifications,
Advanced. Flat rows with hairlines, the button system above, segmented controls, no grouped-box chrome.

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
