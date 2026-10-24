# Tern — visual spec

Direction: **list first**. The window is the mail list: tabs across the title bar, one calm line per
conversation in a centred column, a small floating bar at the bottom. Opening a thread lays it over the list;
Esc puts the list back exactly as it was. Porcelain and graphite neutrals with **one neutral ink** (near-black in
light, near-white in dark) for primary buttons and everything that means *this needs you*. Colour appears only
as a small hue on **tab and tag icons** (and in mail itself). One typeface, **Geist**, and one icon set,
**Hugeicons Stroke Rounded**. Aside-inspired translucent controls and Droppy-inspired glass sit over opaque
mail canvases. Continuous corners and fine light-catching edges distinguish floating controls; shadows stay
behind their backgrounds. The window layout, mail-row density and keyboard model remain unchanged. Research behind the original direction:
`research.md`. Visual reference: the offscreen renders (`--snapshot`, see "Checking it" below); the old static
`mockup.html` is retired.

Hard rules
- Never a coloured bar down one side of a row, card or callout. Status is a dot or a tag.
- Buttons, text and dots are neutral ink. Hue lives only on tab and tag icons; "needs reply" stays ink.
- Text buttons, account controls and the floating toolbar use pill silhouettes; ordinary icon controls use
  continuous 8 pt corners. The prominent compose button stays round.
  Sidebar rows use continuous 12 pt corners. Sender avatars remain rounded squares (a quarter of their side).
- At most three visible actions in any area. Everything else lives in one `…` menu or ⌘K; secondary controls
  appear on hover.
- Every action has a shortcut; ⌘K lists each command with its key.
- No spinners or skeletons for cached mail. No white flash when HTML mail loads.
- No pointer cursor, no hover highlight on everything (web tells). Hover only on rows, tabs and icon buttons.

## Tokens

| Token | Light | Dark |
| --- | --- | --- |
| `bg` list, reader canvas | `#FAFBFC` | `#202020` |
| `sidebar` glass tint and solid fallback | `#EFF1F4` | `#202020` |
| `raised` editor, glass tint and solid fallback | `#FFFFFF` | `#303030` |
| `hover` | `#ECEEF2` | `#363636` |
| `selected` selected row, active tab | `#E4E8EF` | `#363636` |
| `selectedFocus` selected row while the list has the keyboard | `#DBE1EA` | `#404040` |
| `hairline` row separators | `#E5E8ED` | `#363636` |
| `hairlineStrong` tag outlines, field focus, bars | `#CED3DC` | `#4A4A4A` |
| `text1` | `#1B1E24` | `#FAFAFA` |
| `text2` previews, tag labels, icons | `#565D69` | `#D9D9D9` |
| `text3` times, counts, date headers | `#687181` | `#A3A3A3` |
| `ink` primary fill, unread dots, needs-reply icon, focus ring, links | `#18181B` | `#E5E5E5` |
| `inkHover` / `inkPressed` | `#2E2E33` / `#45454B` | `#FAFAFA` / `#CFCFCF` |
| `inkSoft` | `#E4E8EF` | `#363636` |
| `onInk` label on an `ink` fill | `#FFFFFF` | `#202020` |
| `avatarFill` / `avatarText` letter avatars | `#E5E9F0` / `#535E70` | `#363636` / `#B3B3B3` |

Dark neutrals follow the supplied Aside screenshot: canvas `#202020`, panels near `#303030`, and
bubbles near `#363636`. Aside's CSS uses neutral-900 at 80% alpha for its page, not a solid `#202020`.
Its foreground is `oklch(98.5% 0 0)`, with 85% primary and 55% muted text. The opaque text and selection
tokens above adapt that hierarchy to Tern's dense mail list. Light colours retain Tern's existing palette.

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

`Theme.Radius`: **chip 4** (tags, recipient tokens, keycaps, search marks) · **control 8** (fields and compact
segmented controls) · **row 8** (mail, menu and palette fills) · **overlay 12** (toasts, the chord
HUD, the search field, small overlays) · **card 16** (⌘K, popovers, the composer card).
Navigation rows use radius 12; buttons and tabs use half-height corners; the bottom toolbar uses radius 18.
Continuous corners. 4 px grid. Floating glass has a separate black silhouette: light uses 12 pt blur,
8 pt downward offset and 8% opacity; dark uses 6 pt blur, 4 pt offset and 10% opacity. Never rasterize the glass and its content together to
cast a shadow. Existing opaque overlays retain their older shadow treatment.

### Glass and readability

`Shared/GlassSurface.swift` owns `.glassSurface(radius:kind:)`. Sidebar and title chrome form continuous
planes. Dark floating panels have a single 0.5 pt near-white edge at 15% alpha. Light panels also have
an inset white highlight that fades downward. Dark material tints cover 96% of shell chrome and 92% of
floating panels; light uses 72% sidebar and 82% floating/header tints on the custom backdrop path.
Those native material tints are Tern adaptations, not recovered Aside constants. Aside's regular session
composer uses an 8% near-white fill, 15% edge and small shadow without persistent backdrop blur.
Mail-list selection remains opaque, with no per-row blur.

`GlassControlFill` draws a wash and 0.5 pt edge without another backdrop. Dark controls use near-white
at 8%, 10% and 15% for rest, hover and press. Light controls use ink at 3.5%, 6.5% and 10% with a two-tone edge. Active tabs use
the hover wash. Text buttons and tabs are 28 pt pills; the small button variant is 24 pt. Icon controls retain
their rectangular hit area. Sidebar rows use the dark `selected` fill or an 8% light ink selection wash,
6% hover and 12% press. These component
shapes replace the earlier uniform rounded rectangles; mail rows keep their existing shape and density.

The material reuses the sign-in notch's `WindowBackdrop`, a 6 pt live blur. It uses private `CABackdropLayer`
and `CAFilter` APIs and remains a compatibility risk. If those classes are unavailable, floating panels use
Liquid Glass on macOS 26 or SwiftUI material on older systems; sidebar and headers use `NSVisualEffectView`.
Reduce Transparency or Increase Contrast replaces the glass with solid `sidebar` or `raised` fills.

Native decorative backdrops return nil from hit testing and refuse window dragging. The title bar owns
its drag region; decorative materials must not change input behavior.

Never put a backdrop in a mail row, message body, editor canvas, or scrolling cell. The reusable AppKit table,
local database reads, scroll behavior and keyboard selection remain unchanged. Buttons compress on the short
Droppy-derived press spring and release on a softer spring; fills and list hover remain immediate.

## Type: Geist

Bundled in `Resources/Fonts` (SIL OFL 1.1): Geist Regular, Medium and SemiBold, version 1.401, matching
Aside's content font. Static weights 400, 500 and 600 were instantiated with fontTools from Aside's
Latin, Latin-ext and Cyrillic Geist Variable WOFF2 assets, then merged per weight. The license comes from
vercel/geist-font tag 1.4.2. These are open-source Geist fonts, not Aside's separate branded display face.
The source's tabular digit advances differ slightly. Tern normalizes the ten `.tf` digit advances to
`zero.tf` at each weight so counts align; proportional glyph metrics and all outlines remain unchanged.
No installed Aside app or font-generation tool is needed to build or run Tern.
Registered at launch. `Theme.ui(size, weight)` for text, `Theme.numeric(size, weight)`
for anything with figures that should line up (Geist's tabular figures, `tnum`), `Theme.display(size)` for
headlines. No serif, no monospace in the interface (mail's own `<pre>` keeps a system monospace).

| Use | Font |
| --- | --- |
| UI default, row text | Geist 13/18 |
| Row sender | Geist 13, 600 `text1` unread, 400 `text2` read |
| Row subject | Geist 13, 500 `text1` unread, 400 `text2` read; preview 400 `text3` |
| Small, meta, tags | Geist 11.5–12, tags 500 |
| Date headers | Geist 12 500, sentence case, `text3`, left in line with the avatars, vertically centred |
| Sidebar section labels | Geist 12 500, sentence case, `text2` |
| Times, counts, keycaps | Geist 12 tabular (`numeric`) |
| Tabs | Geist 13, 500 active / 400 others; count 12 tabular `text3` |
| Open thread subject | **Geist SemiBold 23/30**, −0.3 tracking |
| Empty states, headlines | Geist SemiBold 17–20 (onboarding 30), −0.2 to −0.5 tracking |
| Reading body (plain text mail) | Geist 14/22, max line 680 |

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
| primary | 28 (small 24) | 12 (small 10) | Geist Medium 13 (12), `onInk` | `ink` fill | `inkHover` | `inkPressed` |
| secondary | 28 (small 24) | 12 (small 10) | Geist Medium 13 (12), `text1` | glass control wash and fine edge | stronger wash | strongest wash |
| quiet | 28 (small 24) | 12 (small 10) | Geist Medium 13 (12), `text1` | nothing | `hover` fill | `selected` fill |
| icon | 28 × 28 (24–26 in rows) | — | 16 px Hugeicon, `text2` | nothing | 5% light / 7.5% dark text wash | 12% text wash |
| link | text | — | Geist Medium 12, `ink` | — | underline | 60 % |

Text buttons use half their height as the radius. Ordinary icon buttons use continuous 8 pt corners with no
hover border. Keyboard focus: a 1.5 px `ink` ring at 50 %, 2.5 px outside the control.
Disabled: 50 % opacity, without hover, press compression or focus rings. Row and tab
buttons use the same disabled treatment, without compression.
Secondary controls reveal on keyboard or accessibility focus as well as hover. Hidden controls ignore clicks.
Native menus anchor 4 pt below their trigger, including keyboard and accessibility activation; they do not
depend on the current mouse event. AppKit handles menu tracking and dismissal.
Segmented choices are native buttons with selected accessibility state, keyboard focus and disabled semantics;
their existing sliding thumb stays behind the immediate press fill.
While held, text buttons shrink to 97 % and icon buttons to 95 %. Press uses response 0.14, damping 0.82;
release uses response 0.24, damping 0.74. Fills stay instant; no shrink with Reduce Motion.
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
  mail is the list itself; with inbox tabs off All counts its unread). 28 px tall, radius 14; active = glass
  control wash and Medium text; hover and press add a neutral wash at once. A tab is as wide as its Medium title, so
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
  account ⌘1…⌘9, Add account…, Settings…) inside a glass control pill; then **compose**: a 28 px round ink
  button with an `onInk` pencil (`c`, ⌘N). No notification bell.

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
    coloured icon, label Geist 11.5 500 `text2`. Needs reply (ink reply icon) first, then the project or the
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
    Snooze and More keep their selected wash and the toolbar visible while their native menus track.
    Sidebar and window resizing reposition both the cursor fill and hover toolbar using the new column bounds.
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
A floating glass toolbar centred under the list, 14 px from the bottom, radius 18,
4 px padding, three 28 px icon buttons — **Search** (`/`, ⌘F when no thread is on screen),
**Sidebar** (⌃⌘S), **Settings** (⌘,). A button whose thing is open gets the glass control wash. Hidden while a
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
- A centred reading column ~720 px. Subject Geist SemiBold 23/30, then tags (the row's filled style; the account last while several are signed in), then the
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
- Bottom: the reply field ("Reply to Maya…", 36 px, radius 8, glass) in the reading column with ✦ quick
  replies on hover; `r` or a click expands the inline reply card in place. The card rises out of the field
  (opacity, 98 % scale from the bottom and 6 pt, 150 ms; an 80 ms fade with Reduce Motion) with the keyboard
  already in it; only the card moves, never the web view. Closing, it sinks back into the field (opacity and 98 %, 120 ms).

### Sidebar
Hidden by default; the bottom bar or ⌃⌘S slides it in beside the list (232 px, `sidebar` surface, under the
title bar; remembered; Reduce Motion crossfades). Mailboxes (Inbox, Needs reply, Snoozed, Starred, Drafts,
Sent, Archive, All mail, More → Spam, Trash and the scoped account's labels), `Projects` (with `+` on hover;
drag rows onto a project or label), `Accounts` (All accounts and each account, when there are several), and
pinned at the bottom one quiet sync line (`text3`; hollow ring up to date, filled dot syncing, `ink` dot when
something needs you) with the sun/moon switch (⇧⌘L) and Settings grouped in one quiet capsule. Rows 32 pt,
radius 12, 16 pt icons in `text2`, tabular counts in 20 pt capsules. Row spacing is 2 pt, section spacing 18 pt.
Selection and press washes appear immediately; rows open on release. Mailbox and account selection remain
independent. The sync line permits two lines and crossfades between states, never within one.
Project menu buttons remain in the view tree, reveal on row or button focus, and stay visible during menu
tracking. The 24 pt button replaces the unread capsule while visible; it is not nested inside the row button.

### ⌘K palette
Centred 640 px, radius 16, shared floating glass with an opaque selected row. 52 px input (Geist 16).
Results grouped: Actions (keycaps right-aligned), Go to, Threads, Projects, Labels, Accounts, Settings, each with
its Hugeicon. ↑↓ / ⌃N ⌃P, Enter runs, ⌘Enter runs on all selected threads. Fades in over 120 ms; closes at once.
Pointer selection requires movement in screen coordinates. Rows moving beneath a stationary pointer cannot
overwrite keyboard selection. Only keyboard and query changes scroll to the selected row. Results expose
button actions and selected state to accessibility, while keyboard navigation stays in the search field.

### Composer
Inline in the reader, or a floating window for new mail (`c`), 640×560. Glass chrome surrounds opaque fields
and editor content; the inline card has radius 16. Flat rows with
hairlines: From (several accounts), To (tokens radius 4), Cc/Bcc (⌘⇧C/⌘⇧B), Subject (Geist 15/600). Rich text
with a formatting bar on selection (Hugeicons bold, italic, underline, link, lists, quote). Bottom bar: Send
(⌘↵) with the send-later chevron (⌘⇧L), paperclip, ✦ Write with AI (⌘J), discard at the far right.
The formatting bar fades in and grows from 97 % toward the selection on first show (120 ms); moving to a new
selection and hiding are instant. "Writing…" shimmers while the AI works, and its draft crossfades in over the old
text (180 ms). The × on the signature and attachment chips fades in on hover (90 ms) and hides at once. Under
Reduce Motion: fades only, 80 ms, and no shimmer. Cc/Bcc, the AI bar, tokens and typing never animate.

### Update card and prompts
Tern's own small floating card, never Sparkle's or a stock alert: 380 pt wide, `raised`, radius 10, 1 px
`hairlineStrong`, the overlay shadow, borderless and movable by its background. The app icon (44 pt) sits at the
top left beside the title (Geist 14 semibold) and one line of `text2` detail; content below aligns with the text: a
3 pt `ink` progress line on `inkSoft` while something runs, "What's new" (caps label, Geist 12.5 bullets, scrolling
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
  title Geist 13, detail 12 `text3`, the control on the right. Small caps (`CapsLabel`) group rows inside a
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
four steps (Google client, Accounts, AI, Done), each with a Geist SemiBold 30 headline (the first is "Mail at
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
  Buttons scale too while held: text buttons 97 %, icon buttons 95 %, with the short press/release springs.
  The reader page's small controls stay at 97 % over 100 ms on the house curve.
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
- The floating sign-in card is the one exception to the short timings: it floats outside the window, so it moves
  like a physical object. It drops in on a spring (response 0.47, damping 0.76) from 86 % × 70 % of its size, 14 pt
  higher and transparent, and lifts away slower without overshoot (0.54, 0.9). It leans to 101.2 % under the pointer;
  its buttons spring to 97 % (the close circle 95 %) while held. Copy → Copied pops the glyph (0.3, 0.6). Liquid Glass
  on macOS 26, tinted dark so the white text reads on any wallpaper; solid with Reduce Transparency or Increase
  Contrast. Values in `Motion.floating*`.
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
Render offscreen by default: `TERN_DB=<copy of a seeded db> TERN_SNAPSHOT_EXTRAS=1 .build/debug/Tern
--snapshot <dir>` writes the list, Gmail's tabs (Primary, Promotions with its count, the title bar alone, ⌘K's Move to …),
reader, reading pane, sidebar, search, narrow window, palette, the settings page
(every section, search, a shortcut being recorded, in conflict, reserved and kept for text editing, an image sender
that couldn't be removed), onboarding, the update card's states and the move prompt in light and dark; `--check` drives the shell through its
behaviour and timings (Gmail's tabs: landing on Primary, Tab / ⇧Tab, counts, a hidden empty tab, Move to Primary and its undo).

Offscreen captures use the solid glass fallback because `cacheDisplay` cannot composite native backdrops.
To check glass, use the built app with a disposable fake database and isolated preferences:

```sh
CFFIXED_USER_HOME=<scratch-home> TERN_DB=<disposable-fake-db> \
  TERN_GLASS_SNAPSHOT_ONLY=1 TERN_SNAPSHOT_LIVE=1 \
  build/Tern.app/Contents/MacOS/Tern --fake --snapshot <output-dir>
```

This briefly shows the fixture over a synthetic desktop and captures only its rectangle. It sends no
mouse or keyboard events, then closes its windows. It covers inbox, palette, reader, inline composer,
settings, a narrow window and a control-state fixture in both appearances. The fixture shows enabled and
disabled buttons, project controls at rest and during menu tracking, plus rest, hover and press washes;
it does not simulate pointer interaction.
Captures alone do not establish keyboard navigation or VoiceOver behavior.
Omit `TERN_SNAPSHOT_LIVE` for the solid fallback.
Never use a real mailbox for this command; snapshots change selection and can create disposable drafts.
