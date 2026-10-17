// The reader's own script. Installed by the app as a WKUserScript in an isolated content world, so the
// page (mail content) can neither see `Tern` nor reach the message handler. Mail HTML never runs
// script: the page CSP is `script-src 'none'` and content JavaScript is off.
(() => {
  'use strict';
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tern;
  const post = (message) => { try { handler.postMessage(message); } catch (_) { /* detached */ } };

  const ICON_FILE = '<svg viewBox="0 0 16 16"><path d="M4 2h5l3 3v9H4z"/><path d="M9 2v3h3"/></svg>';
  const ICON_IMAGE = '<svg viewBox="0 0 16 16"><rect x="2.5" y="3" width="11" height="10" rx="1.5"/><circle cx="6" cy="6.5" r="1.2"/><path d="M3 12l3.5-3.5 2.5 2.5 1.5-1.5 2.5 2.5"/></svg>';
  const ICON_CHEVRON = '<svg viewBox="0 0 10 10"><path d="M2 3.5l3 3 3-3"/></svg>';
  const MIN_SCALE = 0.45;

  let baseSheet = null;
  let state = null;
  let hoverHref = null;
  let fitQueued = false;

  const esc = (value) => String(value == null ? '' : value).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const root = () => document.getElementById('thread');
  const messageElement = (id) => root().querySelector(`.msg[data-id="${CSS.escape(id)}"]`);

  function sheet() {
    if (!baseSheet) {
      baseSheet = new CSSStyleSheet();
      const source = document.getElementById('mail-base');
      baseSheet.replaceSync(source ? source.textContent : '');
    }
    return baseSheet;
  }

  function afterPaint(callback) {
    if (document.visibilityState === 'hidden') { setTimeout(callback, 0); return; }
    requestAnimationFrame(() => requestAnimationFrame(callback));
  }

  // MARK: Markup

  function headerHTML(p) {
    let html = `<header class="head"><h1 class="subject">${esc(p.subject || '(no subject)')}</h1><div class="chips">`;
    for (const chip of p.chips || []) {
      const style = chip.color ? ` style="--chip:${esc(chip.color)}"` : '';
      html += `<span class="chip ${esc(chip.kind || '')}"${style}>${esc(chip.text)}</span>`;
    }
    return html + `</div>${summaryHTML(p.summary)}</header>`;
  }

  function summaryHTML(s) {
    if (!s || s.state === 'none') return '<div class="summary" hidden></div>';
    if (s.state === 'action') {
      return `<div class="summary action" data-act="summary"><span class="spark">✦</span><span class="text">${esc(s.label || 'Summarize')}</span></div>`;
    }
    if (s.state === 'loading') {
      const line = s.text ? `<p>${esc(s.text)}</p>` : '<p>Summarizing…</p>';
      return `<div class="summary loading"><span class="spark">✦</span><div class="text">${line}</div></div>`;
    }
    const clickable = s.expandable ? ' clickable' : '';
    let body;
    if (s.state === 'bullets' && s.bullets && s.bullets.length) {
      body = `<ul>${s.bullets.map((b) => `<li>${esc(b)}</li>`).join('')}</ul>`;
    } else {
      body = `<p>${esc(s.text || '')}${s.expandable ? '<span class="fold">More</span>' : ''}</p>`;
    }
    return `<div class="summary${clickable}" data-act="summary"><span class="spark">✦</span><div class="text">${body}</div></div>`;
  }

  function lineHTML(m) {
    const draft = m.draft ? '<span class="draft">Draft</span>' : '';
    return `<div class="line" data-act="toggle"><span class="av" style="--hue:${esc(m.hue)}">${esc(m.initials)}</span>` +
      `<span class="from">${esc(m.from)}</span>${draft}<span class="snip">${esc(m.snippet)}</span>` +
      `<time class="date mono">${esc(m.date)}</time></div>`;
  }

  function headHTML(m) {
    const address = m.email && m.email !== m.from ? `<span class="addr">${esc(m.email)}</span>` : '';
    let details = '';
    for (const [label, value] of m.details || []) details += `<dt>${esc(label)}</dt><dd>${esc(value)}</dd>`;
    return `<div class="mhead" data-act="collapse"><span class="av" style="--hue:${esc(m.hue)}">${esc(m.initials)}</span>` +
      `<div class="who"><div class="row1"><span class="name">${esc(m.from)}</span>${address}</div>` +
      `<span class="to" data-act="details">${esc(m.toLine)}${ICON_CHEVRON}</span></div>` +
      `<time class="date mono" title="${esc(m.dateFull)}">${esc(m.dateLong || m.date)}</time></div>` +
      `<dl class="details" hidden>${details}</dl>`;
  }

  function imageNoteHTML(m) {
    const blocked = m.body && m.body.blocked;
    if (!blocked || m.imagesAllowed) return '';
    const who = m.email ? ` from ${esc(m.email)}` : '';
    return `<div class="imgnote"><span>Images hidden</span><span>·</span>` +
      `<span class="load" data-act="images" role="button">Load images${who}</span></div>`;
  }

  function attachmentsHTML(m) {
    if (!m.attachments || !m.attachments.length) return '';
    let html = '<div class="atts">';
    for (const a of m.attachments) {
      html += `<div class="att" tabindex="0" data-att="${esc(a.id)}" title="${esc(a.name)}">${a.kind === 'image' ? ICON_IMAGE : ICON_FILE}` +
        `<span class="name">${esc(a.name)}</span><span class="size mono">${esc(a.size)}</span></div>`;
    }
    return html + '</div>';
  }

  function messageHTML(m, open, extraClass) {
    const classes = ['msg'];
    if (open) classes.push('open');
    if (m.unread) classes.push('unread');
    if (extraClass) classes.push(extraClass);
    return `<article class="${classes.join(' ')}" data-id="${esc(m.id)}">${lineHTML(m)}${headHTML(m)}` +
      `${imageNoteHTML(m)}<div class="mbody" data-mode="${esc(m.body ? m.body.mode : 'plain')}"></div>${attachmentsHTML(m)}</article>`;
  }

  /// Long runs of collapsed messages show the first one, a "N more" row, then the last two.
  function messagesHTML(p) {
    let html = '<section class="msgs">';
    const list = p.messages;
    let index = 0;
    while (index < list.length) {
      if (state.expanded.has(list[index].id)) {
        html += messageHTML(list[index], true);
        index += 1;
        continue;
      }
      let end = index;
      while (end < list.length && !state.expanded.has(list[end].id)) end += 1;
      const run = list.slice(index, end);
      if (run.length >= 5 && !state.showAll) {
        html += messageHTML(run[0], false);
        const hidden = run.slice(1, -2);
        html += `<div class="more" data-act="more"><span class="count">${hidden.length}</span><span>more messages</span></div>`;
        for (const m of hidden) html += messageHTML(m, false, 'hidden-run');
        for (const m of run.slice(-2)) html += messageHTML(m, false);
      } else {
        for (const m of run) html += messageHTML(m, false);
      }
      index = end;
    }
    return html + '</section>';
  }

  // MARK: Rendering

  function render(p) {
    const started = performance.now();
    const previous = state && state.key === p.key ? state : null;
    state = {
      key: p.key, payload: p, messages: new Map(), expanded: new Set(), bodies: new Map(),
      openQuotes: previous ? previous.openQuotes : new Set(), focus: previous ? previous.focus : -1,
      showAll: previous ? previous.showAll : false,
    };
    for (const m of p.messages) {
      state.messages.set(m.id, m);
      if (m.body) state.bodies.set(m.id, m.body);
      const wasOpen = previous && previous.messages.has(m.id) ? previous.expanded.has(m.id) : m.expanded;
      if (wasOpen) state.expanded.add(m.id);
      if (previous && !m.body && previous.bodies.has(m.id) && previous.messages.get(m.id).bodyVersion === m.bodyVersion) {
        state.bodies.set(m.id, previous.bodies.get(m.id));
      }
    }
    const scrollTop = previous ? document.scrollingElement.scrollTop : 0;
    const container = root();
    container.innerHTML = headerHTML(p) + messagesHTML(p);
    container.dataset.key = p.key;
    for (const id of state.expanded) mount(id);
    applyFocus(false);
    fitAll();
    if (previous) {
      document.scrollingElement.scrollTop = scrollTop;
    } else {
      scrollToTarget(p);
    }
    const built = performance.now() - started;
    afterPaint(() => post({ type: 'rendered', key: p.key, ms: performance.now() - started, buildMs: built }));
    return built;
  }

  function scrollToTarget(p) {
    const target = p.messages.find((m) => m.target);
    const element = target && messageElement(target.id);
    if (!element || element === root().querySelector('.msg')) { window.scrollTo(0, 0); return; }
    const top = element.getBoundingClientRect().top + window.scrollY;
    window.scrollTo(0, top > window.innerHeight * 0.4 ? top - 8 : 0);
  }

  function mount(id) {
    const element = messageElement(id);
    if (!element) return false;
    const host = element.querySelector('.mbody');
    if (host.shadowRoot) return true;
    const body = state.bodies.get(id);
    if (!body) {
      host.innerHTML = `<span class="pending">${esc(state.messages.get(id).snippet || '')}</span>`;
      post({ type: 'needBody', id });
      return false;
    }
    host.textContent = '';
    host.dataset.mode = body.mode;
    const shadow = host.attachShadow({ mode: 'open' });
    shadow.adoptedStyleSheets = [sheet()];
    if (body.css) {
      const style = document.createElement('style');
      style.textContent = body.css;
      shadow.append(style);
    }
    // `.tern-root` stands in for the mail's <html>, `.tern-body` for its <body>; mail CSS can't reach the host.
    const outer = document.createElement('div');
    outer.className = 'tern-root';
    const wrapper = document.createElement('div');
    wrapper.className = 'tern-body';
    if (body.bodyStyle) wrapper.setAttribute('style', body.bodyStyle);
    wrapper.innerHTML = body.html;
    outer.append(wrapper);
    shadow.append(outer);
    shadow.addEventListener('load', () => queueFit(), true);
    shadow.querySelectorAll('.tern-quote-toggle').forEach((toggle, index) => {
      if (state.openQuotes.has(`${id}#${index}`)) setQuote(toggle, true);
    });
    return true;
  }

  function fit(host) {
    const body = host.shadowRoot && host.shadowRoot.querySelector('.tern-body');
    if (!body) return;
    body.style.zoom = '';
    host.classList.remove('wide');
    const available = body.clientWidth;
    const needed = body.scrollWidth;
    if (available > 0 && needed > available + 2) {
      const scale = available / needed;
      body.style.zoom = String(Math.max(scale, MIN_SCALE));
      if (scale < MIN_SCALE) host.classList.add('wide');
    }
  }

  function fitAll() {
    root().querySelectorAll('.msg.open .mbody').forEach(fit);
  }

  function queueFit() {
    if (fitQueued) return;
    fitQueued = true;
    requestAnimationFrame(() => { fitQueued = false; fitAll(); });
  }

  // MARK: Messages

  function setOpen(id, open) {
    const element = messageElement(id);
    if (!element) return;
    if (open) {
      state.expanded.add(id);
      element.classList.add('open');
      element.classList.remove('hidden-run');
      mount(id);
      fit(element.querySelector('.mbody'));
    } else {
      state.expanded.delete(id);
      element.classList.remove('open', 'details-open');
    }
    post({ type: 'expanded', id, open });
  }

  function toggle(id) { setOpen(id, !state.expanded.has(id)); }

  function order() {
    return Array.from(root().querySelectorAll('.msg:not(.hidden-run)')).map((element) => element.dataset.id);
  }

  function applyFocus(scroll) {
    root().querySelectorAll('.msg.focused').forEach((element) => element.classList.remove('focused'));
    if (state.focus < 0) return;
    const ids = order();
    const element = messageElement(ids[Math.min(state.focus, ids.length - 1)]);
    if (!element) return;
    element.classList.add('focused');
    if (scroll) element.scrollIntoView({ block: 'nearest' });
  }

  function move(delta) {
    const ids = order();
    if (!ids.length) return;
    if (state.focus < 0) {
      const target = state.payload.messages.find((m) => m.target);
      const index = target ? ids.indexOf(target.id) : -1;
      state.focus = index >= 0 ? index : ids.length - 1;
    }
    state.focus = Math.min(ids.length - 1, Math.max(0, state.focus + delta));
    applyFocus(true);
  }

  function toggleFocused() {
    const ids = order();
    if (state.focus < 0) move(0);
    const id = ids[Math.min(Math.max(state.focus, 0), ids.length - 1)];
    if (id) toggle(id);
    applyFocus(true);
  }

  function setQuote(toggleElement, open) {
    const quote = toggleElement.nextElementSibling;
    if (!quote || !quote.classList.contains('tern-quote')) return;
    quote.hidden = !open;
    toggleElement.classList.toggle('open', open);
    toggleElement.setAttribute('aria-label', open ? 'Hide quoted text' : 'Show quoted text');
  }

  // MARK: Events

  function pathOf(event) {
    return event.composedPath().filter((node) => node instanceof Element);
  }

  function linkIn(path) {
    return path.find((node) => (node.localName === 'a' || node.localName === 'area') && node.hasAttribute('href'));
  }

  document.addEventListener('click', (event) => {
    if (!state) return;
    const path = pathOf(event);
    const link = linkIn(path);
    if (link) {
      event.preventDefault();
      const href = link.getAttribute('href');
      if (href.startsWith('#')) {
        const shadow = link.getRootNode();
        const name = decodeURIComponent(href.slice(1));
        if (!name) return;
        const target = shadow.getElementById ? (shadow.getElementById(name) || shadow.querySelector(`[name="${CSS.escape(name)}"]`)) : null;
        if (target) target.scrollIntoView({ block: 'start' });
        return;
      }
      post({ type: 'link', href, text: (link.textContent || '').trim().slice(0, 300) });
      return;
    }
    const quoteToggle = path.find((node) => node.classList && node.classList.contains('tern-quote-toggle'));
    if (quoteToggle) {
      const host = quoteToggle.getRootNode().host;
      const id = host && host.closest('.msg').dataset.id;
      const toggles = Array.from(quoteToggle.getRootNode().querySelectorAll('.tern-quote-toggle'));
      const key = `${id}#${toggles.indexOf(quoteToggle)}`;
      const open = !quoteToggle.classList.contains('open');
      setQuote(quoteToggle, open);
      if (open) state.openQuotes.add(key); else state.openQuotes.delete(key);
      queueFit();
      return;
    }
    const attachment = path.find((node) => node.dataset && node.dataset.att);
    if (attachment) {
      root().querySelectorAll('.att.selected').forEach((element) => element.classList.remove('selected'));
      attachment.classList.add('selected');
      attachment.focus({ preventScroll: true });
      post({ type: 'attachment', action: event.detail >= 2 ? 'open' : 'select', id: attachment.dataset.att });
      return;
    }
    const action = path.find((node) => node.dataset && node.dataset.act);
    if (!action) return;
    const message = action.closest('.msg');
    const id = message && message.dataset.id;
    switch (action.dataset.act) {
      case 'toggle':
        setOpen(id, true);
        break;
      case 'collapse': {
        const selection = window.getSelection();
        if (selection && !selection.isCollapsed) return;
        if (path.some((node) => node.dataset && node.dataset.act === 'details')) return;
        if (state.expanded.size > 1 || state.payload.messages.length > 1) setOpen(id, false);
        break;
      }
      case 'details': {
        const details = message.querySelector('.details');
        details.hidden = !details.hidden;
        message.classList.toggle('details-open', !details.hidden);
        break;
      }
      case 'more':
        state.showAll = true;
        root().querySelectorAll('.msg.hidden-run').forEach((element) => element.classList.remove('hidden-run'));
        action.remove();
        break;
      case 'images':
        post({ type: 'loadImages', id, sender: state.messages.get(id).email });
        break;
      case 'summary':
        post({ type: 'summary' });
        break;
    }
  });

  document.addEventListener('dblclick', (event) => {
    const attachment = pathOf(event).find((node) => node.dataset && node.dataset.att);
    if (attachment) event.preventDefault();
  });

  document.addEventListener('contextmenu', (event) => {
    const attachment = pathOf(event).find((node) => node.dataset && node.dataset.att);
    if (!attachment) return;
    event.preventDefault();
    attachment.classList.add('selected');
    post({ type: 'attachment', action: 'menu', id: attachment.dataset.att, x: event.clientX, y: event.clientY });
  });

  document.addEventListener('mouseover', (event) => {
    const link = linkIn(pathOf(event));
    const href = link ? link.getAttribute('href') : null;
    if (href === hoverHref) return;
    hoverHref = href;
    post({ type: 'hover', href, text: link ? (link.textContent || '').trim().slice(0, 300) : null });
  });

  document.addEventListener('mouseleave', () => {
    if (hoverHref !== null) { hoverHref = null; post({ type: 'hover', href: null }); }
  });

  document.addEventListener('keydown', (event) => {
    if (!state || event.metaKey || event.ctrlKey || event.altKey) return;
    const active = pathOf(event)[0];
    if (active && (active.isContentEditable || /^(input|textarea|select)$/i.test(active.localName))) return;
    const attachment = active && active.dataset && active.dataset.att ? active : null;
    if (event.key === 'Enter' && active && linkIn([active])) return;
    switch (event.key) {
      case 'n': move(1); break;
      case 'p': move(-1); break;
      case 'Enter': case 'o':
        if (attachment) { post({ type: 'attachment', action: 'open', id: attachment.dataset.att }); break; }
        if (active && active.classList && active.classList.contains('tern-quote-toggle')) { active.click(); break; }
        toggleFocused();
        break;
      case ' ':
        if (!attachment) return;
        post({ type: 'attachment', action: 'quicklook', id: attachment.dataset.att });
        break;
      case 'r': case 'a': case 'f':
        if (event.shiftKey) return;
        post({ type: 'key', key: event.key });
        break;
      default:
        return;
    }
    event.preventDefault();
    event.stopPropagation();
  }, true);

  new ResizeObserver(() => queueFit()).observe(document.getElementById('thread'));

  // MARK: API for the app

  window.Tern = {
    render,
    /// Header-only refresh (chips, summary) without touching message state.
    updateHeader(p) {
      if (!state || state.key !== p.key) return;
      state.payload.chips = p.chips;
      state.payload.summary = p.summary;
      const head = root().querySelector('.head');
      if (head) head.outerHTML = headerHTML(state.payload);
    },
    setSummary(key, summary) {
      if (!state || state.key !== key) return;
      state.payload.summary = summary;
      const element = root().querySelector('.summary');
      if (element) element.outerHTML = summaryHTML(summary);
    },
    /// Bodies sanitized after the first paint (collapsed messages), or on demand.
    setBodies(key, bodies) {
      if (!state || state.key !== key) return;
      for (const [id, body] of Object.entries(bodies)) {
        state.bodies.set(id, body);
        if (state.expanded.has(id)) {
          const host = messageElement(id).querySelector('.mbody');
          if (!host.shadowRoot && mount(id)) fit(host);
        }
      }
    },
    setTheme(theme) { document.documentElement.dataset.theme = theme; },
    next() { move(1); },
    previous() { move(-1); },
    toggleFocused,
    expandAll() {
      if (!state) return;
      state.showAll = true;
      root().querySelectorAll('.msg.hidden-run').forEach((element) => element.classList.remove('hidden-run'));
      const more = root().querySelector('.more');
      if (more) more.remove();
      for (const id of state.messages.keys()) if (!state.expanded.has(id)) setOpen(id, true);
    },
    selectedAttachment() {
      const element = root().querySelector('.att.selected') || (document.activeElement && document.activeElement.dataset && document.activeElement.dataset.att ? document.activeElement : null);
      return element ? element.dataset.att : null;
    },
    setAttachmentBusy(id, busy) {
      const element = root().querySelector(`.att[data-att="${CSS.escape(id)}"]`);
      if (element) element.classList.toggle('busy', busy);
    },
    clear() { state = null; root().innerHTML = ''; window.scrollTo(0, 0); },
    fontsReady() {
      return Promise.all(['400 13px Geist', '500 13px Geist', '600 13px Geist', '400 12px "Geist Mono"', '500 24px Newsreader']
        .map((font) => document.fonts.load(font))).then(() => true);
    },
  };

  sheet();
  post({ type: 'boot' });
})();
