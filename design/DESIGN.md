# Tern — visual spec

Direction: **list first**. The window is the mail list: tabs across the title bar, one calm line per
conversation in a centred column, a small floating bar at the bottom. Opening a thread lays it over the list;
Esc puts the list back exactly as it was. Chalk and charcoal neutrals with **one neutral ink** (near-black in
light, near-white in dark) for primary buttons and everything that means *this needs you*. Colour appears only
as a small hue on **tab and tag icons** (and in mail itself). One typeface, **Inter**, and one icon set,
**Hugeicons Stroke Rounded**. Flat surfaces separated by hairlines, small corners, shadows only on floating
things. Calm like Linear and ChatGPT, never the stock macOS look. Research behind the original direction:
`research.md`. Visual reference: the offscreen renders (`--snapshot`, see "Checking it" below); the old static
`mockup.html` is retired.

Hard rules
- Never a coloured bar down one side of a row, card or callout. Status is a dot or a tag.
- Buttons, text and dots are neutral ink. Hue lives only on tab and tag icons; "needs reply" stays ink.
- Nothing is a pill. Only status dots and the account stack are round; sender avatars are rounded squares
  (a quarter of their side), like app icons.
- At most three visible actions in any area. Everything else lives in one `…` menu or ⌘K; secondary controls
  appear on hover.
- Every action has a shortcut; ⌘K lists each command with its key.
- No spinners or skeletons for cached mail. No white flash when HTML mail loads.
- No pointer cursor, no hover highlight on everything (web tells). Hover only on rows, tabs and icon buttons.

## Tokens

| Token | Light | Dark |
| --- | --- | --- |
| `bg` window, list, reader over the list | `#FFFFFF` | `#141414` |
| `sidebar` | `#F6F6F5` | `#0E0E0E` |
| `raised` reading pane, bottom bar, popovers | `#FFFFFF` | `#1A1A1A` |
| `hover` | `#F1F1EF` | `#1F1F1F` |
| `selected` selected row, active tab | `#EBEBE8` | `#272727` |
| `selectedFocus` selected row while the list has the keyboard | `#E4E4E0` | `#2F2F2F` |
| `hairline` row separators | `#E6E6E2` | `#2A2A2A` |
| `hairlineStrong` tag outlines, field focus, bars | `#D6D6D1` | `#3A3A3A` |
| `text1` | `#161616` | `#ECECEA` |
| `text2` previews, tag labels, icons | `#5F5F5A` | `#A3A39E` |
| `text3` times, counts, date headers | `#74746E` | `#85857F` |
| `ink` primary fill, unread dots, needs-reply icon, focus ring, links | `#18181B` | `#EDEDEA` |
| `inkHover` / `inkPressed` | `#2E2E33` / `#45454B` | `#D9D9D5` / `#C4C4BF` |
| `inkSoft` | `#E4E4E0` | `#303030` |
| `onInk` label on an `ink` fill | `#FFFFFF` | `#141414` |
| `avatarFill` / `avatarText` letter avatars | `#E8E8E4` / `#55554F` | `#2E2E2E` / `#B4B4AE` |

On a selected row, `text3` text switches to `text2`. Search matches get an `ink` 13% mark behind the word.
The AI sparkle icon is `text3`. Errors are `ink` 500 text (no red). Destructive confirmations stay in `NSAlert`.

### Where hue is allowed

Tab and tag icons only, 12–14 px, never their text, never a fill:

| Icon | Light | Dark |
| --- | --- | --- |
| People (person) | `#2F6FD8` | `#6EA2FF` |
| Newsletter (leaf) | `#1E9E5A` | `#4CC38A` |
| Notification (bell) | `#C98500` | `#F0B429` |
| Receipt (invoice) | `#138A7E` | `#3CC8B4` |
| Calendar | `#4F5BD5` | `#8C95FF` |
| Promotion (discount tag) | `#DD6B1D` | `#FF9E57` |
| Security (shield) | `#C2334A` | `#FF6B81` |
| Social tab (heart) | `#7C5CDB` | `#A78BFA` |
| Needs reply, All, Other, Important, labels, searches | `ink` / `text2` / `text3` | same |
| Project | the project's colour (Graphite, Blue, Green, Violet, Sand, Rose, Teal, Slate) | same |

Gmail's tabs borrow the category icons: Primary the People person, Promotions the Promotion tag, Updates the
Notification bell, Forums a quote mark in Receipt's teal; Social is a heart in its own violet.

AI provider marks (onboarding, Settings → AI) are the one other place colour shows: Claude's mark in its own
`#D97757`, OpenAI's (for Codex) in `text1`. Only ever next to the provider's name (`scripts/brandlogos.py`).

Account hues (`#4F7CAC #8A6FB3 #3E9A86 #8F7F62 #B05C7A #6B7F4A`, named Blue, Violet, Teal, Sand, Rose, Olive)
mark whose mail a row is: an 8 px dot in the hue on the avatar's lower right, ringed 1.5 px in whatever is behind
the row, only while several accounts share a list (its tooltip names the account). Account avatars (title bar,
scope menu, sidebar, From menu) are the account's Google profile photo, kept on disk and refreshed weekly in the
background; without one, its initial on the hue, softly (18% light, 32% dark). The reader shows the account as a
tag with the same dot. Each account's name and hue are set in Settings → Accounts.

### Radius and spacing

`Theme.Radius`: **chip 4** (tags, recipient tokens, keycaps, search marks) · **control 6** (buttons, icon
buttons, tabs, fields) · **row 6** (row, sidebar, menu and palette fills) · **overlay 8** (toasts, the chord
HUD, the search field, small overlays) · **card 10** (⌘K, popovers, the composer card, the bottom bar).
Continuous corners. 4 px grid. Overlay shadow (palette, menus, toasts): `0 8 30 rgba(0,0,0,.14)` light, `.5`
dark; the bottom bar rests lower (`0 4 12`, `.12` / `.5`). Never a shadow on a button.

## Type: Inter

Bundled in `Resources/Fonts` (OFL): Inter Regular, Medium, SemiBold and Inter Display SemiBold (the optical
size for large text). Registered at launch. `Theme.ui(size, weight)` for text, `Theme.numeric(size, weight)`
for anything with figures that should line up (Inter's tabular figures, `tnum`), `Theme.display(size)` for
headlines. No serif, no monospace in the interface (mail's own `<pre>` keeps a system monospace).

| Use | Font |
| --- | --- |
| UI default, row text | Inter 13/18 |
| Row sender | Inter 13, 600 `text1` unread, 400 `text2` read |
| Row subject | Inter 13, 500 `text1` unread, 400 `text2` read; preview 400 `text3` |
| Small, meta, tags | Inter 11.5–12, tags 500 |
| Date headers | Inter 12 500, sentence case, `text3`, left in line with the avatars, vertically centred |
| Section caps (sidebar) | Inter 11 500, +0.6 tracking, `text3` |
| Times, counts, keycaps | Inter 12 tabular (`numeric`) |
| Tabs | Inter 13, 500 active / 400 others; count 12 tabular `text3` |
| Open thread subject | **Inter Display SemiBold 23/30**, −0.3 tracking |
| Empty states, headlines | Inter Display SemiBold 17–20 (onboarding 30), −0.2 to −0.5 tracking |
| Reading body (plain text mail) | Inter 14/22, max line 680 |

## Icons: Hugeicons Stroke Rounded

The free Hugeicons set (MIT). `scripts/hugeicons.py` reads the npm package `@hugeicons/core-free-icons` as data
and writes `Sources/Tern/Shared/Hugeicons.swift` (one `Icon` case per icon Tern uses, as path data on the 24
grid) plus the reader page's few inline SVGs. To add one: add a line to `ICONS` and run the script.

- Drawn at stroke 1.5 on the 24 grid, scaled (1 pt at 16 pt), round caps and joins, tinted by the caller:
  `IconView` (SwiftUI), `Icon.draw(in:color:)` (AppKit rows), `Icon.image(size:)` (template images for menus
  and SwiftUI `Menu` labels), `Icon.svgMarkup` (the reader page).
- Sizes: 16 in buttons, tabs 14, sidebar 16, row glyphs 14, tag icons 12, inline 11–12.
- Default colour `text2`; quiet `text3`; ink only for compose and needs reply. Hue only per the table above.
- No SF Symbols anywhere in the app.

## Buttons

One system (`TernButtonStyle`, `IconButtonStyle`, `LinkButtonStyle` in `Shell/Components.swift`):

| | Height | Padding | Label | Rest | Hover | Pressed |
| --- | --- | --- | --- | --- | --- | --- |
| primary | 28 (small 24) | 12 (small 10) | Inter Medium 13 (12), `onInk` | `ink` fill | `inkHover` | `inkPressed` |
| secondary | 28 (small 24) | 12 (small 10) | Inter Medium 13 (12), `text1` | 1 px `hairlineStrong` border | `hover` fill | `selected` fill |
| quiet | 28 (small 24) | 12 (small 10) | Inter Medium 13 (12), `text1` | nothing | `hover` fill | `selected` fill |
| icon | 28 × 28 (24–26 in rows) | — | 16 px Hugeicon, `text2` | nothing | `hover` fill | `selected` fill |
| link | text | — | Inter Medium 12, `ink` | — | underline | 60 % |

All radius 6. Keyboard focus: a 1.5 px `ink` ring at 50 %, 2.5 px outside the control. Disabled: 40 % opacity.
While held, text buttons also shrink to 97 % and icon buttons to 95 % (100 ms, house curve; the fill stays
instant; no shrink with Reduce Motion).
At most one primary per area. The Send button is one `ink` block split by a 1 px `onInk` 22 % rule into Send and
a send-later chevron. Segmented controls: a 28 pt `selected` track, the chosen segment `raised` with a
`hairlineStrong` border, radius 4 inside 6; the segment slides to a new choice (180 ms, house curve; an 80 ms
crossfade with Reduce Motion). Switches are tinted `ink`.

## Window

Hidden title bar (`fullSizeContentView`, transparent), our own background. Minimum 960×600, default 1320×840.

```
┌─ ● ● ●  All  Needs reply 24  [Primary]  Promotions 12  Social 3  …  +  ⋯ ──── (P)(N)(K) 3 accounts  [✎] ┐  52
│   Today                                                                                                │
│   (F) Figma (4)            • Priya mentioned you in Mobile app — We're leaning…  [🔔 Notification]  4h │  40
│   (G) Google Drive         • Sofia shared "Lumen — SOW" with you — We hit the…   [◎ Lumen]          4h │
│   …                                                                                                    │
│                                        [ ⌕  ▯  ⚙ ]                                                     │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Title bar (52 px)
- Traffic lights at (16, 18), then the **tabs**, left-aligned after an 84 px gutter.
- Tabs: `All` · `Needs reply` · Gmail's tabs `Primary · Promotions · Social · Updates · Forums` (inbox tabs;
  off in `⋯` → Inbox Tabs or Settings → Layout) · pinned tabs (projects, labels of the account in scope, saved
  searches). The inbox opens on Primary (launch, the sidebar's Inbox, `g i`); All is the whole inbox. A Gmail tab
  other than Primary with nothing in the scope's inbox is hidden, except while it is open; the tabs shown are
  right in the first frame (a cheap probe), the counts follow off the main thread. A thread is in the tab
  of its Gmail category (the newest message from someone else that has one); mail Gmail hasn't categorised goes
  by Tern's category (promotion and newsletter → Promotions, notification and receipt → Updates, the rest and
  unclassified mail → Primary). Each: 14 px icon (hue per the table), title, count in tabular `text3`: unread on
  Promotions, Social, Updates and Forums, waiting threads on Needs reply, none on All and Primary (their unread
  mail is the list itself; with inbox tabs off All counts its unread). 28 px tall, radius 6; active = `selected`
  fill and Medium text; hover = `hover`; pressed = `selected` at once. A tab is as wide as its Medium title, so
  turning active never shifts its neighbours; the active fill slides to the next tab (130 ms, the cursor's curve).
- A mailbox opened from the sidebar, ⌘K or a `g` chord (Sent, Starred, Drafts…) or a search that isn't
  pinned shows as a temporary tab at the end while it is open.
- `+` pins a project, a label or the current search. `⋯` holds tabs that don't fit (the active tab always
  fits), then Unpin, Mark All as Read, Select All, Density, Inbox Tabs, Reading Pane. Right-click a tab to
  pin or unpin it.
- Keys: Tab / ⇧Tab cycle the tabs shown; ⌥1 All, ⌥2 Needs reply, ⌥3–⌥7 Primary to Forums (a key the user had
  given another command before Gmail's tabs stays theirs; that tab then starts without one).
- Right side: the **account stack** (up to three 20 px account avatars, overlapping by 6 px with a 2 px `bg`
  ring: each account's Google profile photo, else its initial in the account hue) + "3 accounts" (or the scoped account's name) opens the scope menu (All accounts ⌘0, each
  account ⌘1…⌘9, Add account…, Settings…); then **compose**: a 28 px icon button, ink pencil, `hairlineStrong`
  outline (`c`, ⌘N). No notification bell.

### List
- A centred column: full width minus 8 px margins when narrow, 28 px margins from 760 px, at most **1040 px**.
- **Date headers**, 38 px, sticky: `Today · Yesterday · This week · Earlier this month ·` month names · years,
  left-aligned with the avatars in `text3`, centred in their height, hairline below across the column. No line
  under the title bar: the window draws no separator, and the scroll edge pocket macOS puts behind a floating
  header (a line across the whole window) is hidden (`ListScrollView`). Every list is in date order; nothing floats to the top.
- **Rows** (NSTableView, custom-drawn, fixed heights, reused): one line at **40 pt** when the list is ≥ 600 px
  wide, two lines at 56 pt otherwise (the reading pane). Density Comfortable (40 pt) / Compact (32 pt); both are
  one line when wide. Read rows step back to `text2` so unread mail is what the eye lands on.
  - One line: 22 px avatar · sender column (20 % of the column, 160–220 px: name, then `(13)` message count in
    tabular `text3`; "Draft to Maya" in italic `text2` with a pencil) · 6 px `ink` unread dot · subject (500 when
    unread) — preview in `text2` (or ✦ sparkle + AI summary) · paperclip · tags · time (tabular `text3`,
    right-aligned: "17m", "3h", "Tue", "Oct 12", "Oct 12 '25").
  - Two lines: avatar · sender (count) · dot … tag · paperclip · time, then subject — preview.
  - **Avatar**: a rounded square (radius a quarter of its side): the sender's domain logo (`SenderLogos`, full
    bleed on white; a logo that is its own rounded tile with see-through corners is cropped just inside the tile
    and backed with its own colour so no white corners show; a faint ring only for white-edged logos in light
    mode, never in dark, where it reads as a border; `LogoTile`), else one initial on `avatarFill`, with the account's dot while several accounts share the list. Logos are asked for
    as rows come into view; rows on screen refresh when one arrives. Spam and Trash show initials only (no
    fetch, no cached logo), in the list and the reader.
  - **Sender names** drop a bot's `[bot]`: `vercel[bot]` reads "Vercel".
  - **Tags**: soft filled chips, no border: 20 px tall, radius 4, `text1` at 5 % (light) / 7 % (dark), 12 px
    coloured icon, label Inter 11.5 500 `text2`. Needs reply (ink reply icon) first, then the project or the
    category (not People/Other). A category tag that only repeats the list stays off: the Gmail tab it files
    under (Notification in Updates, Promotion in Promotions), or the category more than half of the first 40
    threads share (eight at least). Two at most on one line, one on two lines; dropped before they squeeze the subject.
  - Hairline separators across the column. Hover and selection are fills, never a ring: the column's width,
    radius 6, 2 px in from the row's top and bottom. The hairline under a filled row and the one above it (a
    date header's too) go, so a fill never sits between two lines. Hover: `hover` fill and three icon buttons
    replace tags and time: Archive (Move to Inbox in the Archive mailbox), Snooze, `⋯`; on a draft row Discard
    and `⋯`. Selected: `selected` fill; the cursor row gets `selectedFocus` while the list has the keyboard in the
    key window, so focus shows without a ring. Selected neighbours join into one block. The row's icon buttons: `selected` under the
    pointer (the row already has `hover`), `selectedFocus` pressed.
- A row's `⋯` and right-click list every thread action with its key, and Move to Tab ▸ Gmail's tabs (the
  selection's own ticked); ⌘K has Move to Primary … Move to Forums. The move swaps Gmail's category label (every
  other category comes off, also one Gmail adds before the move lands), so Gmail files it there too, and like
  archive the row leaves a tab it no longer belongs to, with undo: each message goes back to the tab it was in
  when you moved it, also in Gmail.
- Triage: `e` archives, the row collapses (160 ms, quick ease-out) and the next row is selected in the same frame;
  a row that slides under a still pointer gets its hover buttons at once. Undo (`z`) slides the row back down into
  place (160 ms); a few new threads at the top of a list scrolled to the top slide in the same way.
  Anything else (paging, search refreshes, mail arriving out of sight) appears at once.
  Toast bottom-centre (36 px, radius 8, `ink` fill): "Archived · Undo z" (4 s), above the bottom bar.
- Archived mail is in the **Archive** mailbox (sidebar, `g e`): conversations someone else wrote in, and notes you
  sent yourself, that aren't in the inbox, snoozed, spam or trash, newest first, no count. There the archive buttons
  become Move to Inbox (⇧I), with the same toast and undo, and `e` does nothing.
- Drafts: on a draft row (the Drafts mailbox, a local draft, a thread of nothing but drafts) the trash keys and the
  `⋯` menu's Move to Trash become **Discard Draft**; a conversation with your draft in it keeps Move to Trash and
  gets Discard Draft in `⋯` and ⌘K. "Draft discarded · Undo" (5 s, wall-clock) brings it back exactly: Gmail's
  copy is deleted only after the undo window, and an undo too late for that says so. A selection of draft rows and
  conversations is discarded and trashed together ("Trash and Discard Drafts", one toast, one undo). A draft
  being sent is never discarded; the toast counts only the drafts that were.
- Empty: inbox zero (All, Primary) is the tern, "Nothing needs you." (Display 20) and a `text3` tally; when triage
  empties the list it arrives in sequence (fades in over the end of the collapse, the tern drawn as one stroke in
  900 ms, then the text rises 4 pt), otherwise it is simply there. Other lists one Display 17 line in `text2`.

### Bottom bar
A floating toolbar centred under the list, 14 px from the bottom: `raised`, radius 10, 1 px `hairlineStrong`,
the bar shadow, 4 px padding, three 28 px icon buttons — **Search** (`/`, ⌘F when no thread is on screen),
**Sidebar** (⌃⌘S), **Settings** (⌘,). A button whose thing is open gets the `selected` fill. Hidden while a
thread covers the list.

### Search
`/`, ⌘F or the bar's search button reveals the field above the list: the column's width, 36 px, radius 8,
`hover` fill, `hairlineStrong` border while focused, search icon, "Search mail", a Pin button once there are
results, an `esc` keycap. Typing turns the list into results (matches marked); the dropdown under the field
suggests people, labels, projects, operators, recent searches and ✦ Ask. ↓ moves into the results, Esc
closes the dropdown, then the search. A search can be pinned as a tab.

### Reader
- Enter, `o` or a click opens the thread **over the list** (same window, `bg` surface, a fade with a 12 px
  slide on the pane spring; a crossfade with Reduce Motion). Esc or the ← button goes back with the selection kept; j/k move to the
  next thread while reading; the list underneath keeps its scroll position.
- ⌘\ shows the **reading pane** instead: list (resizable, 340 px min, two-line rows) · hairline · reader on
  `raised`. Remembered (Settings → Layout).
- Top bar 52 px: ← back on the left (over the list only) and the hover-only "12 of 48" with ‹ ›; on the right
  Archive (Move to Inbox in the Archive mailbox), Snooze, `⋯` as icon buttons (`⋯` has Move to Tab with inbox
  tabs on).
- A centred reading column ~720 px. Subject Inter Display 23/30, then tags (the row's filled style; the account last while several are signed in), then the
  AI summary line (sparkle icon, `text2`). Older messages collapse to one-liners with 24 px avatars; the latest
  unread (or last) message is open: 28 px rounded-square avatar (logo or initials), sender 600 + address `text3`, "to me"
  disclosure, date in tabular `text3`. Your draft in the conversation shows Edit · Discard on its line (`text2`
  links); Discard takes the draft alone. The focused message (n/p) and a selected attachment get the `selected`
  fill, no ring. Bodies in the WKWebView (transparent before first paint, sanitized,
  remote images blocked until "Load images"; Tern's own avatars come as `data:` URLs, which the CSP allows while
  it still allows no remote image). Mail that paints its own colours sits on a white card in dark mode and always
  sees a light colour scheme: its `prefers-color-scheme: dark` styles and `color-scheme` never apply. Attachments
  as chips. Quoted text behind a `•••` toggle.
- Motion on the page is for clicks only; `render()` (every j/k), n/p, Enter and Expand All never animate. A
  message, quoted text or the "N more" rows opened by a click fade in with a 4 px (quotes 3 px) drop, 140 ms on the
  house curve (the rows 20 ms apart, at most 100 ms); collapsing is instant. Attachments, `+`, `···` and the
  "N more" count shrink to 97 % while pressed (the `•••` toggle to 94 %). "Summarizing…" carries a slow shimmer;
  the summary's lines then rise in 40 ms apart (four at most), only when it arrives. Remote images that haven't
  painted after the first frames fade in as they land (160 ms; cached ones never fade), and a sender logo that
  arrives late fades in over the initials (120 ms). Reduce Motion: 80 ms fades, all at once, no shimmer and no
  press shrink.
- Bottom: the reply field ("Reply to Maya…", 36 px, radius 6, `hover` fill) in the reading column with ✦ quick
  replies on hover; `r` or a click expands the inline reply card in place. The card rises out of the field
  (opacity, 98 % scale from the bottom and 6 pt, 150 ms; an 80 ms fade with Reduce Motion) with the keyboard
  already in it; only the card moves, never the web view. Closing, it sinks back into the field (opacity and 98 %, 120 ms).

### Sidebar
Hidden by default; the bottom bar or ⌃⌘S slides it in beside the list (232 px, `sidebar` surface, under the
title bar; remembered; Reduce Motion crossfades). Mailboxes (Inbox, Needs reply, Snoozed, Starred, Drafts,
Sent, Archive, All mail, More → Spam, Trash and the scoped account's labels), `PROJECTS` (with `+` on hover;
drag rows onto a project or label), `ACCOUNTS` (All accounts and each account, when there are several), and
pinned at the bottom one quiet sync line (`text3`; hollow ring up to date, filled dot syncing, `ink` dot when
something needs you) with the sun/moon switch (⇧⌘L). Rows 28 px, radius 6, 16 px icons in `text2`, counts
tabular; `selected` the moment a row is pressed, opened on release. The sync line crossfades between states, never
within one.

### ⌘K palette
Centred 640 px, radius 10, translucent `raised` at 92% with blur, overlay shadow. 52 px input (Inter 16).
Results grouped: Actions (keycaps right-aligned), Go to, Threads, Projects, Labels, Accounts, Settings, each with
its Hugeicon. ↑↓ / ⌃N ⌃P, Enter runs, ⌘Enter runs on all selected threads. Fades in over 120 ms; closes at once.

### Composer
Inline in the reader, or a floating window for new mail (`c`), 640×560, `raised`, radius 10. Flat rows with
hairlines: From (several accounts), To (tokens radius 4), Cc/Bcc (⌘⇧C/⌘⇧B), Subject (Inter 15/600). Rich text
with a formatting bar on selection (Hugeicons bold, italic, underline, link, lists, quote). Bottom bar: Send
(⌘↵) with the send-later chevron (⌘⇧L), paperclip, ✦ Write with AI (⌘J), discard at the far right.
The formatting bar fades in and grows from 97 % toward the selection on first show (120 ms); moving to a new
selection and hiding are instant. "Writing…" shimmers while the AI works, and its draft crossfades in over the old
text (180 ms). The × on the signature and attachment chips fades in on hover (90 ms) and hides at once. Under
Reduce Motion: fades only, 80 ms, and no shimmer. Cc/Bcc, the AI bar, tokens and typing never animate.

### Update card and prompts
Tern's own small floating card, never Sparkle's or a stock alert: 380 pt wide, `raised`, radius 10, 1 px
`hairlineStrong`, the overlay shadow, borderless and movable by its background. The app icon (44 pt) sits at the
top left beside the title (Inter 14 semibold) and one line of `text2` detail; content below aligns with the text: a
3 pt `ink` progress line on `inkSoft` while something runs, "What's new" (caps label, Inter 12.5 bullets, scrolling
with a soft bottom edge past 168 pt). At most two buttons on the right, secondary then primary; Return and Esc work.
Errors are one quiet `text2` line with OK. States: checking, available (auto-update off), downloading, preparing,
ready ("Tern 0.2.1 is ready" · Later · Restart to update), installing, up to date (manual checks only), error. The
move-to-Applications prompt is the same card: "Move Tern to Applications?" · Not now · Move to Applications.
The card fades in and settles 6 pt into place (180 ms, house curve) and leaves with a fade and a 4 pt lift (120 ms);
shown again while leaving, it turns back. The progress line fills linearly (250 ms per report); its waiting
segment travels back and forth, or with Reduce Motion stays in the middle and breathes. Reduce Motion: 80 ms fades.

### Settings
A page of the main window, not a window or a sheet: ⌘,, the bottom bar's gear, the scope menu and ⌘K open it
over the mail the way a thread opens over the list, with a 140 ms fade (80 ms with Reduce Motion). The mail
underneath doesn't change, so Esc, ⌘[, the title bar's ← or ⌘, again put back the tab, the selection, the
scroll and an open thread, and the keyboard goes where it was (the list, the thread, the search field, the find
bar or an inline reply). If Layout changed the reading pane meanwhile, an open thread stays open in the new layout,
and the keyboard goes to the list when the thread it was in no longer shows. The page remembers its last section.
- Left, where the sidebar goes (232 px, `sidebar` surface, traffic lights at its top): a "Search settings" field
  (28 px, `bg` fill, hairline that strengthens with focus) and the sections as sidebar rows — Accounts, Mail,
  Appearance, Layout, Notifications, AI, Shortcuts, Advanced. The chosen one has the `selected` fill and nothing
  else. ↑ ↓ and ⌃Tab move between them when no field has the keyboard; ⌘F goes to the search.
- Right: a 52 px title bar with ← (back) and "Settings" in `text2`, then a centred column at most 680 wide
  (28 px margins from 760 px, 20 below) with the section title (Display 22) and flat rows with hairlines:
  title Inter 13, detail 12 `text3`, the control on the right. Small caps (`CapsLabel`) group rows inside a
  section (Reading, Writing; Window, Tabs). The bottom bar is hidden under the page.
- Search lists matching settings across sections under their sections' caps, then matching shortcuts; words match
  from their start. Sections without a match fade to `text3` in the list. Return opens the first match's section.
- Shortcuts: a filter field, "Reset All" (quiet), one line of help, then every command by palette group with its
  keys as keycaps (radius 4) flush right. Click a keycap to record; + on hover adds a key; a changed command has a
  5 px `text3` dot and a reset button on hover. While recording, the row sits on a `hover` fill, the keycap reads
  "Type a shortcut" inside a 1.5 px `ink` 55 % border, and one line under it says esc cancels and ⌫ removes the key,
  or why the key can't be used: reserved for macOS, a fixed menu item or text editing (⌃A ⌃E ⌃H ⌃K… with or
  without ⇧ ⌥), or used by another command, with Replace. The row grows for that line (160 ms) and the reset and +
  tools fade in on hover (90 ms). A key that can't be used shakes the keycap (240 ms); with Reduce Motion its
  border flashes to full `ink` instead. Only bare keys can be shared, by a list command and a
  reader command (`p`); a ⌘ or ⌃ key is one menu item. The g chords and ⌘1–⌘9 show as read-only keycaps.
- While the page is open, mail commands don't run (their menu items are disabled), bare keys never reach the
  mail, and ⌘K lists no threads, projects, labels or accounts; appearance, layout, ⌘K and new mail still work.
- Accounts: a new or removed account's row fades with a 6 pt drop while the rows below slide (180 ms). AI
  status lines (Checking… → Ready) crossfade, and a copy button turns into a check with a small scale and blur.
- Accounts: each row starts with the account's dot (a 28 px icon button that lists the six hues) and its name,
  edited in place (a hairline on hover and focus; empty goes back to the address), then the address and sync
  state, Sign in again when needed, and Remove.
- Remote images: taking a sender off the list that can't be saved puts it back, and the row's detail says so.

### Onboarding
Onboarding: one 640×560 window,
four steps (Google client, Accounts, AI, Done), each with an Inter Display 30 headline (the first is "Mail at
the speed you think."), one `text2` line under it, the stepper top right and Back / Continue bottom right. The AI
step shows Claude Code and Codex as two cards (mark, name, what pays for it, live status: Ready; Not signed
in with the sign-in command and a copy button; Not installed with an install link); the chosen card gets a
1.5 px `ink` border and a filled radio mark. "Skip, no AI" sits under them. Settings → AI uses the same marks in
its segmented provider control and the same status line. Steps change in one piece: the new one comes in 16 pt
from the side it lies on (forward from the right, Back from the left) with a fade, on the pane spring; the
stepper's dots and labels crossfade, errors fade in, account rows arrive as in Settings. Reduce Motion: 80 ms
crossfades.

## Motion
Values live in `Shared/Motion.swift`. The house curve is a quick ease-out `0.2, 0.9, 0.25, 1`.

- Cursor fill slides from row to row on j/k and ↑↓ (130 ms), one press at a time in a still list. When the list
  scrolls to follow it, or a key is held, it stays on its row and the rows move under it. A click, jumps of
  more than 12 rows, new lists and Reduce Motion place it at once. It is one view under the rows (`CursorFillView`),
  used while only the cursor is selected.
- A different list (tab, mailbox, scope, leaving search) crossfades in 100 ms; never at launch or per search
  keystroke. Row exit and list collapse 160 ms, house curve. Undo and new mail at the top: rows fade and slide down 160 ms, the
  cursor fill moving in the same animation.
- Active tab fill slides between tabs (130 ms); tabs coming and going fade and scale from 0.96.
- Toasts rise in 160 ms (house curve) and fade out where they are with a scale to 0.97 (120 ms ease-out).
- Palette fades in over 120 ms and closes at once. The `g` chord hint shows only after a 0.4 s hesitation (fades
  and rises 4 pt, 200 ms), stays 2 s, and fades out over 200 ms. Search field 120 ms.
- Hover reveal 90 ms, fade in only, hidden at once: the Projects `+`, a project's `⋯`, the row hover buttons
  when the pointer comes into the list (from row to row they move at once).
- Pressed: rows, tabs and sidebar rows get a fill, instant on mouse-down, action on mouse-up, and never scale.
  Buttons scale too while held: text buttons 97 %, icon buttons 95 %, the reader page's small controls 97 %
  (100 ms, house curve).
- Reader over the list, sidebar and pane changes spring (response 0.32, damping 0.86); the sidebar's More opens on
  the house curve (140 ms), its rows fading down 4 pt.
- Inbox zero after triage: fade 200 ms from 120 ms, stroke 900 ms, text 300 ms from 500 ms.
- Reader page: click reveals 140 ms (`tern-reveal`: opacity + 3–4 px), never in `render()` or on keys; remote
  images fade in 160 ms when they load (not when cached); a late sender logo 120 ms. `--ease` in reader.css.
- Composer: the inline reply card rises out of the reply field (150 ms) and sinks back (120 ms); the formatting bar appears toward the
  selection (120 ms); an AI draft crossfades (180 ms).
- AI waiting shimmer on a 1.4 s loop (still with Reduce Motion); summary lines rise 40 ms apart, at most four.
- Settings: segmented thumb slides 180 ms; account rows arrive and leave (180 ms); the shortcut recorder shakes on
  a rejected key (240 ms). Onboarding steps on the pane spring. Cards (update, move) in 180 ms, out 120 ms.
- Nothing in the triage path over 200 ms, and nothing ever delays an action.

Reduce Motion: 80 ms crossfades only (no slides, offsets or scale; the tern is drawn already).

## Keyboard
See `research.md` §E. Every shortcut can be changed in Settings → Shortcuts; the keys here are the built-in
ones. Changes in this direction: ⌘\ toggles the reading pane (was: the sidebar); ⌃⌘S toggles
the sidebar; ⌘⇧\ is gone (list only is now the default); Tab / ⇧Tab and ⌥1–⌥7 move between tabs; ⌘F searches
mail unless a thread is on screen. Bare-letter keys are inactive while a text field has focus, and so are the ⌘
and ⌃ keys of commands that act on mail (only ⌘K, ⌘N, ⌘,, find, view and appearance keys and the like still work);
the Control keys text fields edit with can't be assigned. The open conversation answers the current keys of Next and
Previous Message, Open and Quick Look itself. After archive or delete with nothing left in the list, the reader
closes whatever the preference. `g` chords time out 2 s after their hint shows (2.4 s in all).

## Checking it
Render offscreen, never on screen: `TERN_DB=<copy of a seeded db> TERN_SNAPSHOT_EXTRAS=1 .build/debug/Tern
--snapshot <dir>` writes the list, Gmail's tabs (Primary, Promotions with its count, the title bar alone, ⌘K's Move to …),
reader, reading pane, sidebar, search, narrow window, palette, the settings page
(every section, search, a shortcut being recorded, in conflict, reserved and kept for text editing, an image sender
that couldn't be removed), onboarding, the update card's states and the move prompt in light and dark; `--check` drives the shell through its
behaviour and timings (Gmail's tabs: landing on Primary, Tab / ⇧Tab, counts, a hidden empty tab, Move to Primary and its undo).
