# Tern — UI/UX design research

Researched 2026-10-17. No app code written. Images are in `inspo/` (30 files, index in section A.4).

## 0. Read this first: what is solid and what is not

**Gaps (be aware before trusting the whole doc):**
- **Dribbble, Behance, Mobbin and X are not covered.** Dribbble returned empty bodies, Mobbin returned 403, Behance returned a stub, and the one X post I tried returned HTTP 402. So there are **no concept-shot images from those sites** and no claims below that depend on them. The "concept" material I do have is product marketing renders (Superhuman, Shortwave, Canary, HEY, Cora, Amie, Craft) and open-source SwiftUI clients. Section A.3 says exactly what that gives you.
- **ChatGPT / Codex desktop, Craft, Reflect, Warp, Cursor, Height, Fastmail, Airmail UI were not analysed in depth.** I only got brand/OG imagery or review snippets for them. The one hard finding on ChatGPT is the July 2026 redesign backlash (A.2). The "ChatGPT/Codex look" below comes from your brief, plus my own memory of the 2024–25 web app (dark `#212121` canvas, `#171717` sidebar), which I did not re-verify for the 2026 desktop app.
- **Several sources are weak.** Notion Mail's shutdown was confirmed by TechCrunch / 9to5Mac / Heise / Android Authority, so that one is solid. Most "review" blogs (email-tools.me, cmdk.email, aiemaily, eesel) are SEO or competitor content: I use them only for feature lists, never for taste claims. The Linear token table is from a **third-party DESIGN.md of linear.app's marketing site, not the app**, so treat it as a style reference, not Linear's real tokens. Complaints about Superhuman's post-Grammarly AI slowdown come from an aggregator (checkthat.ai), unverified. The Spark-redesign complaint is from a search snippet only (the Houston Chronicle page failed to load).
- **Fonts**: I'm confident the ones I recommend are SIL OFL 1.1 (bundleable, redistributable), but that is from my own knowledge, not re-checked online. **Check each font's LICENSE file when you add it to the repo.**
- Contrast ratios in section C were **computed by script** (WCAG 2.x relative luminance). Everything else (px sizes, ms) is a design recommendation, not a measurement of another app, unless I say "seen".

**Source tags used below:** `[seen]` = I looked at the image/page at full size; `[thumb]` = only a small thumbnail; `[text]` = from fetched page text; `[snip]` = search snippet only.

---

## A. Per-app notes

### A.1 Mail clients

**Superhuman** (incl. Sept 2026 redesign)
- Redesign shipped Sept 2026: mobile apps rebuilt (persistent bottom nav for Inbox / Calendar / Search, unified composer for new + reply, "Write with AI" and "Write with Voice" made 2x faster), and **web + desktop got matching themes: "higher contrast, warmer colors, new icons, improved readability"**, a new logo, themes switched from ⌘K → Theme Settings. `[text]` https://blog.superhuman.com/we-redesigned-superhuman-mail-for-ios-and-android/ , https://connect.superhuman.com/t/new-in-mail-redesigned-mobile-apps-desktop-experience/61457 . The desktop redesign is described in one line only; no desktop screenshots were published in what I could fetch.
- Marketing render of the new themes `[seen]` (`inspo/superhuman-new-themes.png`): **list rows are single-line** with no row dividers (the render is cropped, so I can't state a real pixel height). Order: unread dot (blue, 8px) → sender (semibold, ~16px at 2x) → **pastel label chip** (recruiting pink, signature orange, travel green, product yellow) → subject → grey preview → time. Drafts show as green text "Draft to Esther Howard". Top of list = large text tabs with counts: **"Important 12 · VIP 13 · Review 8"** (these are the split-inbox tabs); the active tab is dark, the others grey. A hamburger sits left of the tabs. Left edge is a narrow rail with a sparkle (Ask AI) pill and mail/calendar toggle. Dark theme is warm charcoal (~`#2B2A29`, my eyeball), not blue-black.
- **Do NOT copy:** the selected row in that render has a **purple bar on its left edge plus a lavender fill**. That is the side-accent-bar pattern you hate. Superhuman's own earlier shot (`superhuman-mail-app.png` `[seen]`) uses a thin left bar on the selected row too.
- `superhuman-mail-app.png` `[seen]`: "Ask AI" floating panel (gradient title "Ask AI", bubble reply, `Ask a question` input with a stop button) over a sky-gradient backdrop. Good example of AI as a **small anchored panel**, not a full mode.
- Shortcuts (from keycheck.dev `[text]`): E done, ⇧E undo-done, H remind me, U read/unread, S star, L label, Y remove label, ⇧3 trash, ⇧1 spam, ⇧M mute, J/K next/prev conversation, N/P next/prev message in thread, C compose, R reply, Enter open / reply-all, F forward, ⇧C / ⇧F / ⇧↵ pop-out, ^↵ send, ⇧^↵ send + mark done, ⇧^L send later, `/` search, Tab / ⇧Tab next / previous split, G-chords (GI inbox, GS starred, GD drafts, GT sent, GE done, GH reminders, GM muted, GA all mail, GL label). ⌘K = command palette (also Theme Settings). `^` in that list is the source's notation, which I read as the platform's primary modifier.
- AI: Write with AI (⌘J per Nick Lafferty review), Instant Reply, Auto Summarize (Starter); Auto Drafts, Ask AI, Mail MCP, Custom Auto Labels (Business). Price $25 / $33 per month annual. https://nicklafferty.com/reviews/superhuman/
- Reviewers praise: keyboard speed ("sub-100ms interactions" is a competitor blog's wording), ⌘K, one-key triage. Complain: price, AI slowness after the Grammarly acquisition (aggregator, unverified), no search across all accounts without switching, weak mobile parity, hard cancellation (Reddit-sourced summary). See section G.

**Shortwave**
- Lineage: Google Inbox. Split inbox (tabs by importance / sender / label / custom query), **Bundles** (Newsletters, Promotions, GitHub, invoices collapse into one row for bulk triage; one review says it halved triage work for 100+ mail/day), AI summary at the top of each thread (2–4 sentences), AI search, AI filters in plain English, todos from email, command bar, "keyboard shortcuts for everything". https://www.shortwave.com/ , https://email-tools.me/posts/shortwave-review/ (weak source, features only).
- Marketing render `[seen]` (`shortwave-og.png`): dark navy canvas (~`#0F1024`), **left icon rail** (avatar + status dot, inbox, clock, send), a **Pinned** group (colored rounded-square avatars, "USV Team", "Launch to-dos") above a **"Last 7 days"** group; selected row = muted blue-slate fill; bundle rows show a name + count badge (Newsletters 4, Feedback 5, Promotions 23); a **search field is permanent at the top of the list** ("Search emails, contacts, labels…"). Face avatars on every row.
- Praise: "disgustingly fast", bundles give "the entire big picture at a glance". Complaints: **smart labels "over-eager"** (based on sender, not content), AI **summaries sometimes longer than the email**, **no calendar**, Gmail-only, free-tier AI limits. https://www.producthunt.com/products/shortwave-6/reviews

**Mimestream** (native macOS, Gmail only, $4.99/mo or $49.99/yr)
- Three panes. Left sidebar: **account "profile" buttons at the very top** (icon + name, e.g. Personal / Work, each with its own Focus filter and notification schedule), then Inboxes → Primary → sub-inboxes, Social, Promotions, Updates, Forums with Gmail category icons. `[seen]` (`mimestream-site-preview.png`).
- List rows (seen): **3 lines** (sender + thread count + time; subject; one-line preview), with a **colored pill label** (Inquiries blue, Travel purple, Home green) and an **attachment chip** (filename with icon) under the preview. Toolbar above the reader: archive, trash, mark, folder, label, reply, reply-all, forward + search field. Message view: collapsed older messages with avatar + first line + star.
- Compact or expanded list; **swipe gestures assignable** (Archive, Trash, Label, Snooze, Mark Unread/Starred, Move); supports Gmail **or** Apple Mail shortcut sets. https://www.macstories.net/reviews/mimestream-the-perfect-email-app-for-gmail-users-on-the-mac/
- Praise: genuinely native, fast, full Gmail label/filter fidelity. Complaints: **no scheduled send (a Gmail API limit)**, **"need for denser email list layouts"**, no iOS app, Gmail-only, no AI, subscription. https://www.producthunt.com/products/mimestream/reviews
- Takeaway for Tern: this is the **generic-Mac benchmark** you do not want to look like (stock sidebar, stock toolbar, stock selection color), but its feature set (profiles, Gmail-faithful labels) is the baseline to beat.

**Notion Mail** — **shut down 22 Sept 2026.** TechCrunch/9to5Mac: Notion said "more than half of Notion Mail users manage emails without ever opening their inbox" and pivoted to agents. https://techcrunch.com/2026/06/25/notion-mail-shuts-down-amid-agent-takeover/ , https://9to5mac.com/2026/06/25/notion-shutting-down-its-ai-powered-email-client-including-mac-and-ios-apps/ . While alive: Notion-style left sidebar, user-defined **Views** (filtered inboxes), AI auto-labels from plain-English rules, `/` slash menu in compose. Complaints: setup was manual, Notion integration shallow, drafts generic. Lesson: a pretty inbox with views was not enough; people delegated email entirely. For Tern that argues for AI that **does triage in the background** (classification, "needs reply" queue) so the user opens fewer screens, not more.

**Spark** — Readdle. Smart Inbox, team features, cross-platform, free tier. Reviews: "doesn't feel as obsessed with raw keyboard-first speed as Superhuman". Redesign backlash: a vocal group says the new version is **less compact, slower, less workflow-friendly** `[snip]`. No images used.

**HEY** (37signals)
- Concepts: **Screener** (approve first-time senders), **Imbox** (mail you want), **The Feed** (newsletters, read like a feed), **Paper Trail** (receipts / transactional), **Reply Later** and **Set Aside** stacks pinned at the bottom of the screen, **Focus & Reply** (batch reply mode). https://www.hey.com/how-it-works/ `[text]`
- Visuals `[seen]` (`hey-imbox.jpg`, `hey-reply-mode.png`, `hey-opengraph.png`): giant centered page title ("Imbox", ~64px bold), **orange 8px unread dots**, 60px circular avatars (monogram fallback with bright flat fills: lime, coral, yellow), subject on line 1 at ~20px regular, "Sender — preview" in grey on line 2, date right-aligned; **ALL-CAPS section labels with a hairline** ("NEW FOR YOU", "PREVIOUSLY SEEN"); the Reply Later / Set Aside stacks are drawn as **offset stacked paper cards** at the bottom. Focus & Reply: pill-shaped **mint "Send email"** button, big radius reply box, green "✓ Sent!" capsules. Brand: purple-to-magenta gradient with a hand-drawn waving hand. Loud, friendly, very un-Apple.
- Why it matters: HEY is the best proof that **sorting by purpose (people / feed / receipts) beats sorting by time**, and that a bottom "stack" is a nice, low-chrome way to show pending work. Its personality is too loud for Tern's brief; the structure is the part to steal.
- Complaint evidence: I gathered none for HEY, so I make no claim.

**Cora** (Every) — AI-first. "Your inbox only contains email from humans that need a response", everything else auto-archived and summarised in **twice-daily Briefs**; auto-drafts replies in your voice; $20/mo. https://every.to/p/introducing-cora-manage-your-inbox-with-ai . Polarising: Every's own write-up says people who don't like it quit "almost immediately" https://every.to/source-code/a-time-machine-for-your-email ; a search snippet of Geoffrey Litt's post says it "felt very strange at first (I almost quit)" but "turns email from an inbox into a feed" `[snip]` (the X page itself would not load). Brand `[seen]` (`cora-opengraph.png`): a **postage-stamp logo** on a photographic sky, serif headline in white. Charming, and the stamp motif is relevant to Tern ("mail").

**Zero / 0.email** — open source (Next.js, React, Tailwind, shadcn/ui, Postgres), self-hostable, AI summaries + drafting, Gmail/Outlook/IMAP. https://github.com/Mail-0/Zero . I did not find product screenshots, and the README names no shortcuts. I saw only its dark OG banner (pixel-block mark, bold grotesque), which I deleted as uninformative. Competitor to know about because it is also open source.

**Missive** — team inbox. `[seen]` (`missive-shared-inbox.png`): 4 columns: flat light sidebar with **team spaces** (emoji-style rounded avatars) and labels with colored tag icons; list with avatar + sender + time, subject, a **"[ ] Follow up with Carlos"** task line, checklist counters (⊘ 0/1), small participant avatars, a pill label; reader with **internal chat bubbles inline in the thread** (blue = you, grey = teammate) and **task checkboxes with owner avatar + due pill** under it; far-right icon rail (contacts, tasks, calendar, ChatGPT). Selected row = **solid saturated blue fill with white text**. **Watch out:** rows carry a **thin colored left edge** (red / orange / yellow) in that render. Another example of the side-bar pattern to avoid. Verdict from reviews: "heavier than you need" for solo use. Worth stealing: tasks living as a quiet line inside a thread.

**Canary Mail** — `[seen]` (`canary-meta.png`): dark UI, **pill category tabs** (All filled blue, Primary, Promotions, Social, Updates), toolbar icons grouped inside rounded capsules, a "✦ Summarize this conversation" chip at the top of the reader, **skeleton loading rows (grey bars)** in the list, selected row solid blue. Cheap ($36/yr), privacy-led. Visually the "generic dark SaaS" look.

**Airmail** — reviews point to bugs (lag, freezing, messages missing vs webmail, preferences not saved) `[snip]`. Features-first, not a design reference.

**Fastmail** — only the OG banner seen; not analysed.

**Inbox Zero Mail** (`inbox-zero/inbox-zero-mail`, native SwiftUI variant, **discontinued** — work moved to an Electron app) — **the cleanest minimal list I found.** `[seen]` (`inboxzero-mail-native-mac.png`): a single floating white card with **no sidebar at all**: a hamburger on the left, **text tabs "All 7 · Unread 3 · Starred 2 · Snoozed 1 · Notifications 0"** (active tab dark, others grey, counts in a smaller lighter weight), compose / search / ⌘ icons at the right. Section label "Today". Rows (roughly 37px if the render is 2x, which is my estimate): blue unread dot, gold ★, sender (semibold if unread), **colored pill label in a fixed column**, "**Subject** — preview" on one line, paperclip, **compact relative time ("17m", "1h", "3h")**. No row borders. https://github.com/inbox-zero/inbox-zero-mail . Default keys: ⌘K palette, C compose, E archive, S star, ⇧U read/unread, H snooze.

**Open-source SwiftUI peers** (the real competition for an OSS Mac client): Pepitta (`ankorez/pepitta`; GitHub 404'd on fetch, so only its search blurb: multi-account, threads, snooze, labels), Post (`JackCosta2612/Post`, MIT, light+dark `[thumb]`), Postie (`igorkulman/Postie` `[thumb]`), Swiftmail, Orris. Post and Postie look like **stock Apple Mail clones** (system sidebar, system selection colors). Treat them as the "generic" look to avoid.
- `caffeinum/mail` ("Reply", https://github.com/caffeinum/mail `[text]`): SwiftUI shell + **AppKit `NSTableView` for lists** + **one reused `WKWebView` for HTML mail** + SQLite (WAL) + FTS5, "the last view draws from disk before any network", Gmail REST history deltas, vim keys (j/k, gg/G, o, u, e, #, /, 1/2/3 to switch accounts), self-reported ~150–170 ms to first frame on M-series. Directly relevant architecture for your speed goal (the self-reported numbers are unverified).

### A.2 Non-mail Mac apps

**Linear** — Redesign write-up (Part II, https://linear.app/now/how-we-redesigned-the-linear-ui `[text]`):
- Goal: "reduce visual noise, maintain visual alignment, increase the hierarchy and density of navigation elements"; they obsessed over **pixel-exact alignment of labels, icons and buttons** in the "inverted L" (sidebar + header chrome).
- Themes moved from HSL to **LCH** (perceptually uniform) and from **98 variables per theme to 3: base, accent, contrast**; they deliberately **limited how much accent color the chrome uses** to look "more neutral and timeless" while raising text and icon contrast.
- **Inter Display for headings, Inter for body.**
- Third-party tokens of linear.app marketing site `[text]` (not the app): canvas `#010102`, surface ladder `#0f1011 → #141516 → #18191a`, hairline `#23252a`, text `#f7f8f8 / #8a8f98 / #62666d`, accent `#5e6ad2`, radii 4/6/8/12, **no drop shadows**: depth = surface ladder + 1px hairlines. This is a good model for a flat, ChatGPT-like look.

**Raycast** — "We're not a web app with some native hooks. We're a native app that uses web for its UI." https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast `[text]`
- Removed `cursor: pointer` and **most hover highlights** (they read as "web"); popovers and tooltips are **native windows that can extend past the window bounds**; settings open in **separate native windows, not modals**; translucency on inner panels; uses Liquid Glass on macOS Tahoe; fought hard for **zero flicker / no white flash on open**.
- Takeaway: a lot of "premium" is **absence of web tells and absence of flicker**, not decoration.

**Arc / Dia** (The Browser Company) — "Familiar, but elevated"; a **novelty budget** spent only where no pattern exists (the chat); controls like the bookmark button appear **only on hover**; **page color extends into the tab bar**; URL shown as a human title; fluid animation on the most-used element (the assistant bar); `@` mentions and `/` skills. https://browsercompany.substack.com/p/the-strategy-behind-dias-design `[text]`. Images saved (not viewed at full size): `dia-*.jpg`.

**Things 3** — "UI is invisible"; **a to-do expands into a white sheet of paper** ready for writing; Magic Plus button inserts a task exactly where you drop it; custom animation toolkit; two Apple Design Awards. `[snip]` (https://culturedcode.com/things/features/). `things-all-new.jpg` `[thumb]`: sidebar with **small, distinct colored icons per list** (Inbox blue tray, Today yellow star, Upcoming red calendar, Anytime teal layers, Someday beige box) tilted at an angle on a paper-white window. A good example of **color used only for list identity**, not for chrome.

**Notion Calendar (Cron)** — keyboard-first (C creates, T today, type "8 weeks" to jump). Third-party analysis `[text]` (https://blakecrosley.com/guides/design/notion-calendar): text at `rgba(0,0,0,0.9 / 0.54 / 0.35)`, grid borders `rgba(0,0,0,0.09)`, **4px radius**, **monospaced numerals in the time gutter**, an 8-colour semantic palette, a custom Inter fork. Users say the keyboard-first purity softened after the Notion acquisition `[snip]`.

**Granola** — typefaces **Quadrant (a "mechanical slab serif") for display + Melange for UI**, green identity, hand-drawn imperfect logo, "calm, but with energy underneath". https://www.granola.ai/blog/a-new-look-for-granola `[text]`. Product detail: **your notes are black, AI-added text is grey**, which keeps AI visually subordinate `[snip]`. Branding render `[thumb]` (`granola-identity-1.png`) is poster-like: hot pink, halftone, big serif. **Why it matters:** it proves a productivity app can have a **serif personality in one place** and still be calm.

**Zed** — native, GPU-rendered (Metal) UI via GPUI, 120 fps scroll, "UI fades into the background" `[snip]`. Its OG image `[thumb]` pairs a dark editor with an **italic serif tagline ("Your last next editor")**. Same lesson: sans UI, one serif voice.

**Ghostty** — native Cocoa chrome + Metal renderer, no Electron, "follows platform conventions"; goal: "fast, feature-rich and platform-native" all at once. `[snip]` Image dropped.

**Amie / Craft** — only brand images: Amie's logo is a **3D puffy cloud** on a photographic sky; Craft's wordmark is a **chunky black block display face** on a soft cloud sky. Both show a "sky + soft objects" playfulness. Reviews call Amie "joyful" with smooth animation `[snip]`. No UI analysis.

**ChatGPT / Codex desktop** — the one verified fact: the **9 July 2026 redesign merged Chat, Work and Codex into one app and removed chat history and Projects from the sidebar**; backlash was fast and OpenAI **restored history and Projects to the sidebar by mid-July**. https://www.digitaltrends.com/computing/openai-patches-chatgpt-desktop-after-user-backlash-over-its-recent-redesign/ , https://community.openai.com/t/desktop-app-redesign-removed-chat-history-from-the-sidebar-please-bring-it-back/1386361 . Lesson: **never hide the list/navigation people live in for the sake of minimalism.**

**Reflect, Warp, Cursor, Height**: not analysed (brand images only).

### A.3 Dribbble / Behance / Mobbin / X concepts

Not retrievable (see section 0). What I can say honestly: the freshest-looking *distinctive ideas* in what I did retrieve are (1) **HEY's stacked paper cards** for Reply Later; (2) **Inbox Zero Mail's no-sidebar floating card with text tabs**; (3) **Cora's postage-stamp identity and "brief" instead of a list**; (4) **Shortwave's rail + Pinned + Last 7 days grouping**; (5) **Granola/Zed's single serif voice**; (6) **Amie/Craft's soft photographic sky backdrops and puffy 3D marks**. Everything in section C builds on those. If you want a real concept-shot sweep, someone with a logged-in browser should pull 10 shots from Dribbble `email client` / `inbox` tags.

### A.4 Image index (`inspo/`, 30 files)

| File | What it shows | Seen how |
|---|---|---|
| superhuman-new-themes.png | New light + dark themes, tabs with counts, chips, draft row | full |
| superhuman-mail-app.png | Ask AI panel over list with chips | full |
| superhuman-principle-1.jpg | Mobile list with chips + bottom nav pill | thumb |
| superhuman-principle-2.jpg | Mobile Write-with-AI composer | thumb |
| shortwave-og.png | Dark rail, Pinned/Last 7 days, bundles, search | full |
| mimestream-site-preview.png | Native 3-pane, profiles, pills | full |
| inboxzero-mail-native-mac.png | Minimal card, text tabs, one-line rows | full |
| missive-shared-inbox.png | 4-pane team inbox, inline chat/tasks | full |
| missive-task-view.png | Task list view | thumb |
| missive-opengraph.jpg | Brand banner | not viewed |
| canary-meta.png | Dark UI, pill tabs, skeleton rows | full |
| hey-imbox.jpg | Big title, orange dots, caps section labels, stacks | full |
| hey-reply-mode.png | Focus & Reply, mint pill button | full |
| hey-screener.png / hey-feed.jpg / hey-paper-trail.jpg | HEY feature screens | not viewed |
| hey-opengraph.png | Brand: gradient + hand logo | full |
| cora-opengraph.png | Stamp logo, serif on sky | full |
| post-swiftui-light-dark.png / postie-swiftui-gmail.png | OSS SwiftUI Gmail clients | thumb |
| dia-tab-color-extension.jpg / dia-mention-interaction.jpg / dia-slash-commands.jpg | Dia craft details | not viewed |
| notion-calendar-og.png | Calendar grid + icon stickers | thumb |
| things-all-new.jpg | Angled Things sidebar | thumb |
| granola-identity-1.png | Pink/serif branding | thumb |
| raycast-og.png | Dark red command UI | thumb |
| zed-og.webp | Editor + italic serif tagline | thumb |
| amie-meta.png | 3D cloud mark on sky | full |
| craft-og.png | Block wordmark on sky | thumb |

Note: `dia-*.jpg` were saved with `.png` names at first; renamed to `.jpg` since they are JPEG data.

---

## B. Patterns worth stealing (ranked)

1. **Draw from local disk first, never from the network.** (Reply/caffeinum architecture, Mimestream on-device storage.) *Why:* first frame and every list change happen in <100 ms regardless of Gmail latency; this is the single biggest source of "fast". Actions apply optimistically and sync in the background.
2. **One-key triage with instant undo and auto-advance.** (Superhuman E / Z.) *Why:* removes the decision "where do I go next", and undo removes fear. Row exits in 160 ms, selection moves to the next row in the same frame.
3. **⌘K palette that shows the shortcut next to every command.** (Superhuman, Inbox Zero Mail, Raycast.) *Why:* it teaches the keyboard map for free and doubles as search, settings and theme switcher so you can keep the UI tiny.
4. **Split inbox as plain text tabs with counts, cycled by Tab / ⇧Tab.** (Inbox Zero Mail, Superhuman; AI-filled like Shortwave.) *Why:* one line of chrome shows state; AI classification gives the tabs meaning without user setup.
5. **Chrome in neutral greys, one accent, surfaces separated by hairlines instead of shadows.** (Linear, ChatGPT.) *Why:* reads as calm and deliberate; the accent is then free to mean "needs you".
6. **Derive themes from three inputs (base, accent, contrast) in a perceptual colour space (OKLCH/LCH).** (Linear.) *Why:* light, dark and high-contrast stay consistent, and open-source users can re-theme with 3 values.
7. **Reveal secondary controls on hover, group the rest in one "…" menu.** (Dia, your brief.) *Why:* a row shows at most 3 hover icons; the resting list is only text.
8. **Remove "web tells" and flicker.** (Raycast.) *Why:* no pointer cursor, no hover highlight on everything, native popovers and windows, no white flash on open, no layout jump when HTML mail loads. Feels native without looking like stock macOS.
9. **Monospaced / tabular numerals for times and counts.** (Cron.) *Why:* columns of "17m 1h 3h" and counts align perfectly; tiny cost, big polish.
10. **One typographic voice with personality, everything else quiet.** (Granola slab serif, Zed italic serif, Linear Inter Display.) *Why:* this is how you become "creative but polished" without clutter. Pick one place (reading-pane subject + empty states) and spend personality only there.
11. **AI is visually subordinate and small.** (Granola grey AI text; Shortwave summary at thread top; Canary summarise chip.) *Why:* trust. Cap a summary at 2 lines and never longer than ~40% of the email (Shortwave's "summary longer than the email" complaint). Classification is a small chip, not a banner.
12. **Separate mail you read from mail you act on.** (HEY Imbox / Feed / Paper Trail; Shortwave bundles; Cora briefs.) *Why:* Tern's classifications (needs reply, newsletters, receipts, notifications) map straight onto this; collapsed bundles cut triage work.
13. **Stacks / batch mode for "later".** (HEY Reply Later + Focus & Reply.) *Why:* a bottom stack of 2 cards is low-chrome and makes "needs reply" a ritual with a visible end.
14. **Selection without a side bar.** (Linear neutral fill; Missive/Canary solid fill.) *Why:* you ban the accent bar, and a **full-row neutral fill with 8px radius + a 1.5px ring only when the list has keyboard focus** is more legible and more modern.
15. **A deliberate "inbox zero" moment.** (Things' care for the empty/complete state; Cora's "brief" end-point.) *Why:* closes the loop. I did not verify what Superhuman does here, so this is my recommendation, not a copy.

---

## C. Three visual directions

Shared structural rules (all three): hidden title bar with the content running under it and traffic lights inset at (16, 14); **flat opaque sidebar** (no `NSVisualEffectView`); translucency only on transient overlays (⌘K palette, menus, toasts, at ≤85% opacity with 24px blur); 4px base grid; radii: row/button **8px**, popover/card **12px**, pill controls **999px**, chips **6px**; no drop shadows on resting surfaces (one shadow only on floating overlays: `0 8px 30px rgba(0,0,0,.14)` light / `0 8px 30px rgba(0,0,0,.5)` dark); **never** a colored bar on any card or row edge. Status = dots and chips.

Shared classification chips (12% tint background, colored text; measured on white / `#141414`):

| Class | Light text | Dark text | Contrast (L / D) |
|---|---|---|---|
| Needs reply | per-direction accent-ink | per-direction accent-ink | see below |
| Newsletter | `#6E5BD0` | `#A89BF5` | 5.2 / 7.6 |
| Receipt | `#23764A` | `#5CCB91` | 5.6 / 9.1 |
| Notification | `#5E6B7A` | `#94A3B3` | 5.4 / 7.1 |
| Calendar | `#2F6FD8` | `#78A8FF` | 4.8 / 7.8 |
| Promo / low priority | `#96620E` | `#E0B04F` | 5.2 / 9.2 |

### C1. "Cap & Beak" (Arctic tern: chalk, charcoal, one vermilion)

The tern's white body, black cap and orange-red beak, translated to an interface. Closest to ChatGPT/Codex + Linear; the safest direction.

**Palette (measured contrast in brackets, text vs window bg unless noted):**

| Token | Light | Dark |
|---|---|---|
| window / list bg | `#FFFFFF` | `#141414` |
| sidebar | `#F6F6F5` | `#0E0E0E` |
| raised (reader, cards, popover) | `#FFFFFF` + 1px border | `#1C1C1C` |
| hover | `#F1F1EF` | `#1F1F1F` |
| selected row | `#EBEBE8` | `#272727` |
| hairline | `#E6E6E2` | `#2A2A2A` |
| hairline strong | `#D6D6D1` | `#3A3A3A` |
| text 1 | `#161616` (18.1) | `#ECECEA` (15.6) |
| text 2 | `#5F5F5A` (6.4) | `#A3A39E` (7.3) |
| text 3 | `#74746E` (4.7; 4.3 on sidebar) | `#85857F` (5.0) |
| accent fill (dots, primary button) | `#E5461E` (4.0 as graphic) | `#FF6B3F` (6.5) |
| accent ink (text/links) | `#C23A16` (5.4) | `#FF8C66` (8.1) |
| accent soft (chip bg) | `#FDECE6` | `#2E1913` |

- On a **selected** row, text 3 drops to ~3.9 (light) / 4.0 (dark), so previews on the selected row switch to text 2.
- Primary button: accent ink `#C23A16` fill with white label (5.4:1) in light; `#FF6B3F` fill with `#141414` label in dark.

**Type (all bundled, OFL):** **Geist** (UI + body) with **Geist Mono** for times, counts, shortcut hints. Sizes: UI 13/18, small 12/16, list sender 13/18 semibold, reading-pane subject **22/28 Geist 600, tracking −0.2px**, body 14/22 (max line 680px), section caps 11/14 +0.6px tracking.
**Density:** compact default, 36px single-line rows when the list is wide, 52px two-line when narrow (rule in section F).
**Layout:** sidebar 232px (collapses to 0 with ⌘\), list 400px, reader flexible. Resting sidebar shows only: account switcher, Inbox / Needs reply / Later / Done, Projects, Splits settings. Everything else is in ⌘K.
**Signature "creative" detail: the Flock.** A row of dots above the list, one dot per thread that needs action today (max 12, then "+n"), in accent color. Each triage action removes a dot with a small upward drift (6px, 180ms ease-out, fade). Reaching zero draws a **single-stroke tern silhouette** across the empty state once (900ms stroke-draw, then rest). Cheap to implement (Canvas/Shape path animation), ownable, fits the product name.
**Motion:** row exit 160ms ease-out + list collapse 180ms; pane slide 220ms (spring response 0.32, damping 0.86); palette 120ms (scale .98→1 + fade); hover-reveal 90ms; nothing in the triage path over 200ms. All off under Reduce Motion (crossfade 80ms).
**Avoids generic macOS:** custom flat chrome, bundled Geist instead of SF, vermilion instead of system blue, own selection style.

### C2. "Paper & Ink" (warm paper, one blue ink, a serif voice)

Mail as correspondence. Warm neutrals, a serif for subjects and empty states, the reading pane as a **sheet of paper lifted above the list**. Closest to Granola/Things in spirit and the most distinctive of the three.

| Token | Light ("paper") | Dark ("lamp-lit") |
|---|---|---|
| list bg | `#F4EFE6` | `#1A1814` |
| sidebar | `#EBE5D8` | `#14120F` |
| sheet (reader) | `#FBF8F2` | `#211E19` |
| hover | `#EEE8DB` | `#24211C` |
| selected row | `#E6DFCF` | `#2A2721` |
| hairline | `#DDD5C4` | `#34302A` |
| text 1 | `#1E1B16` (15.0) | `#ECE6D9` (14.3) |
| text 2 | `#5E574B` (6.2) | `#A9A18F` (6.9) |
| text 3 | `#756D5C` (4.5; 4.1 on sidebar) | `#8C8574` (4.8) |
| accent (ink blue; fill and text) | `#2F3FBF` (7.1) | `#8C9BFF` (7.0) |
| accent soft | `#E4E6F7` | `#262A4A` |

**Type (OFL):** **Newsreader** (reading-pane subject 24/30 at 500, empty-state lines, daily brief headings) + **Instrument Sans** (UI, 13/18) + **JetBrains Mono** (times/counts 12/16 tabular). Sender names stay in Instrument Sans 600; only the *subject of the open thread* and moments of "voice" get the serif.
**Density:** comfortable: 52px two-line rows by default, 680px reading column, generous 24px padding in the sheet.
**Layout:** same three panes; the **reader is a sheet** (radius 12px, 1px hairline, `0 1px 0 rgba(0,0,0,.04)` and a 24px inset from the window edge) so list and reader feel like desk and paper.
**Signature detail: the Postmark.** Account identity is a **16px circular postmark** (ring + initial, in each account's muted hue) at the end of the sender line, shown only in unified view. Snoozed mail shows "back Tue" in a rectangular **stamp outline** instead of a clock icon; sent-later shows "leaves 9:00". Pairs with Cora's stamp idea. Subtle, only 3 places.
**Motion:** the sheet slides in 240ms (ease-out-quint) and the list dims 4%; archive = the row **folds** (scaleY to 0 with 4° skew, 170ms), a small paper cue that never delays the next row.
**Risk:** warm cream can feel "retro" or like Notion; needs the cool-grey `text 3` discipline above and no paper texture.

### C3. "Tidepool" (dark-first, deep sea-glass, recency as depth)

Dark is the hero, light is "fog". The one with most atmosphere and the most risk of looking like a generic dark SaaS if the accent is overused.

| Token | Dark (hero) | Light ("fog") |
|---|---|---|
| list bg | `#0E161B` | `#F4F7F8` |
| sidebar | `#080D10` | `#E9EFF1` |
| raised | `#131E25` | `#FFFFFF` |
| hover | `#16222A` | `#E9EFF1` |
| selected row | `#1B2A33` | `#DDE7EA` |
| hairline | `#1F2E37` | `#D5DEE1` |
| text 1 | `#E6EEF0` (15.5) | `#0E1A20` (16.4) |
| text 2 | `#8EA3AB` (6.9) | `#4A5F68` (6.2) |
| text 3 | `#71898F` (4.9) | `#5F7780` (4.4, marginal) |
| accent fill | `#38D6C4` (10.1) | `#0F8F86` (3.7 as graphic) |
| accent ink | `#5EE6D6` (12.0) | `#0B7A72` (4.8) |
| accent soft | `#10302F` | `#D6EEEB` |

**Type (OFL):** **Bricolage Grotesque** for display only (reading-pane subject 22/26 at 600, section titles, empty states; its quirky optical axes give a little character) + **Hanken Grotesk** (UI 13/18) + **JetBrains Mono** (times, counts, shortcut hints).
**Density:** compact, 34px single-line rows, 4px vertical rhythm.
**Layout:** three panes, but the **list scrolls under a floating pill bar** (tabs + search, 36px tall, radius 999px) instead of a toolbar; the pill is the only elevated thing in the window.
**Signature detail: Depth.** **Recency as luminance:** unread/new rows are full brightness; read rows step down in 3 stages (text 1 → 85% → 70% opacity) by age (today / this week / older), so the list literally "sinks" as it ages and the surface is scannable without any colour. A faint **waterline** hairline (dashed, text 3 at 40%) separates "needs reply" above from the rest with the count in mono at its right end.
**Motion:** springs with slightly more float (response 0.38, damping 0.8) on pane changes; triage exit is a quick "sink" (translateY +6px, fade, 150ms).
**Risk:** teal on near-black is the most-used dev-tool palette; works only if the accent stays under ~2% of pixels. Dim-by-age needs an off switch for accessibility (a high-contrast toggle that fixes opacity at 100%).

---

## D. Recommendation

**Pick C1 "Cap & Beak" as the base, and borrow two things from the others.**

Why: it matches your stated taste most directly (ChatGPT/Codex neutrals, flat sidebar, pill controls, Linear's restraint), it has the **fewest ways to go wrong** in SwiftUI (no textures, no multiple font families, no atmospheric effects), it **makes the accent mean something** (vermilion = needs you), and its signature ("the Flock" dots + a drawn tern) is cheap, ownable and tied to the name. It also passes contrast with real numbers, including dark mode as a first-class theme rather than an inversion.

Borrow:
1. From **Paper & Ink**: the **serif voice for exactly two places** (open-thread subject and empty states) via **Newsreader** next to Geist. It is the "somewhat creative" ingredient and costs one font file.
2. From **Tidepool**: the **waterline** hairline between "needs reply" and everything else, and the optional "dim by age" (off by default, in ⌘K → Appearance).

Skip the Postmark and the sheet-lifting layout until the base is shipping. Both are good later experiments.

**Implementation notes that follow from the research (not code):**
- Bundle **static** font files for UI weights (400/500/600) rather than variable fonts; I remember SwiftUI/CoreText handling of variable-weight axes being inconsistent, but I did not verify that in this session, so test it first.
- Use `NSTableView`/`NSCollectionView` (AppKit) for the list, SwiftUI for the rest (the `caffeinum/mail` approach), and one reused `WKWebView` for HTML mail with its background set before first paint to avoid a white flash (Raycast's lesson).
- Derive both themes from three inputs (base, accent, contrast) in OKLCH, as Linear did, so third-party themes are three lines.
- **Send-later cannot rely on the Gmail API.** Mimestream users complain there is no scheduled send because of the Gmail API; Tern's "send later" will probably need an app-side scheduler or a Gmail-side workaround. Design the UI to say honestly when a scheduled send needs the Mac awake. (I did not research the API in depth; confirm before promising.)

---

## E. Recommended keyboard map

Principle: **single keys in the list/thread, ⌘ for global and compose**. Gmail muscle memory first, Superhuman additions second, Mimestream/native conventions for windows. A **"Gmail preset" and "Superhuman preset"** toggle in settings covers the differences. Source column: GM = Gmail (support.google.com), SH = Superhuman (keycheck.dev), MS = Mimestream, VIM = caffeinum/mail, **T = Tern proposal (not copied from anyone, needs testing)**.

| Action | Key | Source / note |
|---|---|---|
| Command palette | ⌘K | SH |
| Search | `/` (⌘F searches inside the open thread) | GM, SH |
| Next / previous conversation | `j` / `k` (also ↓ / ↑) | GM, SH |
| Top / bottom of list | `gg` / `G` | VIM |
| Open thread | `Enter` (or `o`) | GM, SH |
| Back to list | `Esc` (Gmail's `u` is deliberately not used; `u` toggles unread here) | SH |
| Next / previous message in thread | `n` / `p` | SH |
| Next / previous split | `Tab` / `⇧Tab` | SH |
| Jump to split N | `⌥1`–`⌥9` (not ⌃1–9: macOS uses those for Spaces) | T |
| Switch account | `⌘1`–`⌘9`, unified inbox `⌘0` | T (VIM uses bare 1/2/3) |
| Done (archive) | `e` | GM, SH |
| Undo last action | `z` | GM, SH |
| Snooze / remind | `h` | SH |
| Trash | `#` | GM |
| Spam | `!` | GM |
| Star | `s` | GM, SH |
| Mark read/unread (toggle) | `u` in list, `⇧U` also works | SH, GM |
| Mute thread | `m` | GM |
| Select / extend | `x`, `⇧J` / `⇧K`, `⌘A` all | GM, T |
| Label | `l` | SH |
| Move to project | `p` (palette-style picker) | T |
| Mark "needs reply" / clear it | `⇧R` | T |
| Compose | `c` | GM, SH |
| Reply / reply all / forward | `r` / `a` / `f` | GM (SH uses Enter for reply-all) |
| Send | `⌘↵` | GM, SH |
| Send + done | `⌘⇧↵` | SH |
| Send later | `⌘⇧L` | SH variant, T key |
| Write with AI / rewrite | `⌘J` | SH (per review) |
| Summarise thread | `⌘⇧S` | T |
| Go to … | `g i` inbox, `g r` needs reply, `g s` starred, `g d` drafts, `g t` sent, `g e` done, `g h` snoozed, `g a` all mail, `g l` label, `g p` project | GM, SH; `g r`, `g p` are T |
| Toggle sidebar | `⌘\` | T |
| Toggle reader (list-only / split) | `⌘⇧\` | T |
| Shortcut cheat sheet | `?` | GM |
| Settings | `⌘,` | macOS |

Rules: **every shortcut is also a palette entry showing its key**; chords time out at 1s with a tiny HUD showing the pending `g`; shortcuts are inactive while any text field has focus; bare-letter shortcuts are rebindable.

---

## F. List row anatomy (recommended)

Two layouts, chosen **automatically by list width** (and overridable in ⌘K → Density): this resolves the Mimestream "denser list please" complaint and Superhuman's one-line density.

### F1. Wide / compact: one line, 36px (list ≥ 560px, or the list-only layout)

| Slot | Size / style | Notes |
|---|---|---|
| Leading gutter 20px | Unread dot **6px**, accent; or a 14px "needs reply" arrow glyph in accent; empty if read | the only place accent appears on a row |
| Sender | **13/18 semibold** if unread, 500 if read; fixed width 180px, ellipsis | if the thread has several people: "Ana, Ben 3" with the count in text 3 |
| Account postmark | 14px muted monogram (only in unified view) | right after the sender |
| Chip | max **one**, 18px tall, 11/16 weight 500, radius 6px, 12% tint + colored text | **Project > classification** priority; others appear in the reader |
| Subject — preview | subject 13/18 weight 500 text 1; " — " then preview 13/18 text 3; one line, ellipsis | like Inbox Zero Mail / Superhuman |
| Trailing | paperclip 12px text 3 → time **12/16 Geist Mono, tabular**, right aligned 56px | times: "17m", "3h", "Tue", "Oct 12", "Oct 12 '25" (compact like Inbox Zero Mail) |
| Hover (replaces time) | **3 icon buttons 24px**: Done, Snooze, "…" menu | 90ms fade; everything else is in the menu |

### F2. Narrow / comfortable: two lines, 52px (list < 560px, e.g. beside the reader)

- **Line 1 (13/18):** gutter dot · sender (semibold if unread) · thread count · account postmark ······ chip · paperclip · time (mono 12/16).
- **Line 2 (13/18):** subject (500, text 1) — preview (text 3), one line.
- Vertical padding 8px, horizontal 12px, gutter 20px. No avatars by default (they add noise and load cost); optional 24px monogram in settings.

### Row states (no side bars)
- **Rest:** transparent. **Hover:** `hover` fill, radius 8px, inset 6px from the list edge. **Selected:** `selected` fill (full row) + text 3 → text 2. **Keyboard focus:** `selected` fill + **1.5px accent ring at 40% opacity**, only while the list has focus. **Unread:** dot + semibold sender, never a bold subject. **Draft:** subject replaced by "Draft to Esther" in text 2 italic with a pencil glyph (Superhuman shows it in green text; no colored text needed).
- **Group headers:** 11/14 caps, +0.6px tracking, text 3, 28px tall, sticky ("TODAY", "YESTERDAY", "THIS WEEK") with a hairline. Bundles (newsletters etc.) are a single row "Newsletters · 4" that expands in place.
- **Skeletons:** don't show them for cached mail; if shown, use a 60% opacity shimmer of 1.2s at most (Canary's grey bars feel slow).
- **Split tabs above the list:** text tabs 13/18, active = text 1 with a 2px underline in text 1 (not accent), count in text 3 at 12px; one 28px pill "+ Add split" appears only on hover over the tab row.

---

## G. Pitfalls reviewers complain about

| App | Complaint | Source reliability | Tern implication |
|---|---|---|---|
| Superhuman | Price ($25–33/mo) for "a slick overlay on Gmail"; hard to cancel | aggregator / Reddit summary | open source + fair pricing is a real differentiator |
| Superhuman | AI features slowed things after Grammarly acquisition | aggregator, unverified | AI must never block opening a thread; run async, show results when ready |
| Superhuman | No search across all accounts without switching | aggregator | unified, local, instant search is a core promise: make it visible |
| Superhuman | Mobile / Android lags desktop; no unified inbox on mobile | aggregator | Tern is Mac-only: say so; don't promise mobile |
| Shortwave | Smart labels "over-eager" (sender-based, not content) | PH reviews | show confidence; one-key "not this" correction that teaches the model; never auto-archive |
| Shortwave | AI summary sometimes longer than the email | PH reviews | length cap (≤40% of source, max 2 lines in list) |
| Shortwave | Gmail-only; no calendar; free-tier AI limits | multiple | n/a, but local AI avoids limits |
| Mimestream | No iOS app, Gmail only, no AI, subscription; **no scheduled send (Gmail API)**; users want **denser list**; no quick light/dark toggle | PH + MacStories | auto density by width; theme toggle in ⌘K; be honest about send-later limits |
| Notion Mail | **Shut down 22 Sept 2026**; "more than half of users manage email without opening the inbox" | TechCrunch, 9to5Mac (solid) | build AI triage to reduce time in the app, not add reasons to stay |
| Notion Mail | Setup was manual (views); shallow Notion link; generic drafts | review blogs | classification must work with zero setup on day one |
| Spark | Redesign "less compact, slower, less workflow-friendly"; crashes, sync delays | search snippet only | never trade density for decoration in a redesign |
| Airmail | Lag, freezes, messages missing vs webmail, settings not saved | search snippets | **sync correctness beats features**: show sync state; never lose a message |
| ChatGPT desktop | Redesign hid chat history and Projects; patched within about a week | Digital Trends, OpenAI forum | keep the list and navigation people live in visible |
| Cora | Polarising: "if you don't like Cora, you stop using it almost immediately" | Every (vendor) | make AI-first modes opt-in and reversible, with the classic inbox one key away |
| Missive | Heavy for solo users; **colored left edge on rows** (a banned pattern) | review blogs + my reading of its render | keep Tern single-user-simple |
| Generic dark SaaS (Canary, Zero) | Interchangeable look: blue pill tabs, skeleton rows | my read of renders | accent discipline + serif voice + the Flock |

**Cross-cutting rules distilled:**
1. Speed is a promise: no spinner on cached content, no AI in the critical path, no white flash for HTML mail.
2. Never lose or hide mail; never auto-archive on a guess; always offer undo (`z`).
3. Density is an option, not a default religion: auto by width, override in ⌘K.
4. Make AI opt-out per category, show why something was classified (hover/long-press tooltip), and keep corrections one key away.
5. Don't remove the sidebar/list people navigate with in the name of minimalism (ChatGPT backlash).

---

## H. Sources

Mail: https://blog.superhuman.com/we-redesigned-superhuman-mail-for-ios-and-android/ · https://connect.superhuman.com/t/new-in-mail-redesigned-mobile-apps-desktop-experience/61457 · https://nicklafferty.com/reviews/superhuman/ · https://keycheck.dev/apps/superhuman/ · https://www.shortwave.com/ · https://www.producthunt.com/products/shortwave-6/reviews · https://www.macstories.net/reviews/mimestream-the-perfect-email-app-for-gmail-users-on-the-mac/ · https://www.producthunt.com/products/mimestream/reviews · https://techcrunch.com/2026/06/25/notion-mail-shuts-down-amid-agent-takeover/ · https://9to5mac.com/2026/06/25/notion-shutting-down-its-ai-powered-email-client-including-mac-and-ios-apps/ · https://www.hey.com/how-it-works/ · https://every.to/p/introducing-cora-manage-your-inbox-with-ai · https://every.to/source-code/a-time-machine-for-your-email · https://github.com/Mail-0/Zero · https://missiveapp.com/ · https://github.com/inbox-zero/inbox-zero-mail · https://github.com/caffeinum/mail · https://github.com/JackCosta2612/Post · https://github.com/igorkulman/Postie · https://www.getinboxzero.com/blog/post/superhuman-alternatives

Design: https://linear.app/now/how-we-redesigned-the-linear-ui · https://github.com/voltagent/awesome-design-md/blob/main/design-md/linear.app/DESIGN.md (third-party) · https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast · https://browsercompany.substack.com/p/the-strategy-behind-dias-design · https://www.granola.ai/blog/a-new-look-for-granola · https://blakecrosley.com/guides/design/notion-calendar (third-party) · https://culturedcode.com/things/features/ · https://www.digitaltrends.com/computing/openai-patches-chatgpt-desktop-after-user-backlash-over-its-recent-redesign/ · https://community.openai.com/t/desktop-app-redesign-removed-chat-history-from-the-sidebar-please-bring-it-back/1386361 · https://support.google.com/mail/answer/6594 (Gmail shortcuts)
