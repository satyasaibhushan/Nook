// Nook Feed Filtering
(() => {
  'use strict';
  const hosts = { 'x.com': 'x', 'www.x.com': 'x', 'youtube.com': 'youtube', 'www.youtube.com': 'youtube',
    'm.youtube.com': 'youtube', 'reddit.com': 'reddit', 'www.reddit.com': 'reddit', 'old.reddit.com': 'reddit' };
  const site = hosts[location.hostname];
  if (!site || location.protocol !== 'https:' || globalThis.nookFeedFilter) return;
  const LIMIT = 1000;
  const text = (node) => (node?.textContent || '').trim();
  const handle = (value) => value.trim().replace(/^@/, '').toLowerCase();
  const adapters = {
    x: {
      active: () => /^\/(home|search)\/?$/.test(location.pathname),
      roots: 'main [role="region"][aria-label], [data-testid="primaryColumn"] section',
      posts: '[data-testid="tweet"]',
      extract(node) {
        const links = [...node.querySelectorAll('a[href*="/status/"]')];
        const link = links.find((a) => a.querySelector('time')) || links[0];
        const match = link?.pathname.match(/^\/(\w+)\/status\/(\d+)/);
        if (!match) return null;
        return { node: node.closest('[data-testid="cellInnerDiv"]') || node,
          post: { id: `x:${match[2]}`, author: `@${match[1]}`, text: text(node.querySelector('[data-testid="tweetText"]')) } };
      }
    },
    youtube: {
      active: () => location.pathname === '/' || location.pathname === '/watch',
      roots: 'ytd-browse[page-subtype="home"] ytd-rich-grid-renderer, ytd-watch-next-secondary-results-renderer, ytm-rich-grid-renderer, ytm-watch-next-secondary-results-renderer',
      posts: 'ytd-rich-item-renderer, ytd-compact-video-renderer, yt-lockup-view-model, .yt-lockup-view-model, ytm-video-with-context-renderer, ytm-compact-video-renderer',
      extract(node) {
        if (node.parentElement?.closest(this.posts)) return null;
        const title = node.querySelector('#video-title, .yt-lockup-metadata-view-model__title, h3 a, .media-item-headline a');
        const link = title?.closest('a[href]') || title?.querySelector('a[href]') || node.querySelector('a[href*="/watch?"], a[href*="/shorts/"]');
        if (!link) return null;
        const url = new URL(link.getAttribute('href'), location.origin);
        const id = url.searchParams.get('v') || url.pathname.match(/^\/shorts\/([^/]+)/)?.[1];
        if (!id) return null;
        const author = node.querySelector('a[href^="/@"], a[href^="/channel/"], a[href^="/user/"]');
        const path = author?.getAttribute('href') || '';
        return { node, post: { id: `youtube:${id}`, author: path.startsWith('/@') ? path.slice(1).split('/')[0] : path.replace(/^\//, '').replace(/\/$/, '') || text(author), text: text(title) } };
      }
    },
    reddit: {
      active: () => /^\/(?:$|(?:best|hot|new|top|rising)\/?$|r\/[^/]+(?:\/(?:hot|new|top|rising|best))?\/?$)/.test(location.pathname),
      roots: 'shreddit-feed, #siteTable',
      posts: 'shreddit-post, .thing[data-fullname]',
      extract(node) {
        const id = node.getAttribute('id') || node.getAttribute('data-fullname');
        if (!id) return null;
        const author = node.getAttribute('author') || text(node.querySelector('a.author, a[href*="/user/"]')).replace(/^u\//, '');
        const title = node.getAttribute('post-title') || text(node.querySelector('[slot="title"], a.title'));
        const body = text(node.querySelector('[slot="text-body"], .usertext-body'));
        return { node: node.closest('article') || node, post: { id: `reddit:${id}`, author, text: [title, body].filter(Boolean).join('\n') } };
      }
    }
  };
  const adapter = adapters[site];
  let config = { enabled: false, judgeEnabled: false, rules: {} };
  let pageID = crypto.randomUUID();
  let configKey = '', route = location.href, generation = 0, scheduled = false, sending = false;
  let roots = [], observers = [], discovery = null;
  const states = new Map(), cache = new Map(), queue = new Map(), pending = new Set(), overrides = new Map(), counted = new Map();
  let hiddenCount = 0, judgedCount = 0;
  const reasons = new Map();
  const bridge = (body) => {
    try { return Promise.resolve(window.webkit.messageHandlers.nookFeed.postMessage({ ...body, page: route, pageID })).catch(() => ({})); }
    catch { return Promise.resolve({}); }
  };
  const boundedSet = (map, key, value) => {
    map.delete(key); map.set(key, value);
    if (map.size > LIMIT) map.delete(map.keys().next().value);
  };
  const fixedReason = (post) => {
    if ((config.rules.mutedAccounts || []).some((a) => handle(a) === handle(post.author))) return 'Muted account';
    if ((config.rules.keywords || []).some((word) => word.length > 0 && post.text.toLowerCase().includes(word.toLowerCase()))) return 'Matched keyword';
    return null;
  };
  let publishedCount = 0;
  const publish = () => {
    if (publishedCount === hiddenCount) return;
    publishedCount = hiddenCount;
    bridge({ type: 'hidden', count: hiddenCount, judgedCount, reasons: Object.fromEntries(reasons) });
  };
  const summary = () => {
    if (!hiddenCount) return;
    bridge({ type: 'summary', count: hiddenCount, judgedCount, reasons: Object.fromEntries(reasons) });
    hiddenCount = 0; judgedCount = 0; publishedCount = 0; reasons.clear();
  };
  const style = document.createElement('style');
  style.textContent = `
    .nook-feed-hidden,.nook-feed-collapsing {box-sizing:border-box!important;min-height:0!important;padding-top:0!important;padding-bottom:0!important;overflow:hidden!important;max-height:17px!important}
    .nook-feed-hidden > :not(nook-feed-strip) {display:none!important}
    .nook-feed-hidden.nook-feed-open {max-height:none!important}
    .nook-feed-merged {max-height:0!important;min-height:0!important;border:0!important;margin-top:0!important;margin-bottom:0!important}
    .nook-feed-collapsing {transition:max-height .22s ease!important;max-height:var(--nook-feed-height)!important}
    .nook-feed-collapsing.nook-feed-fold {max-height:17px!important}
    .nook-feed-collapsing.nook-feed-fold.nook-feed-merged {max-height:0!important}
    nook-feed-strip {display:block!important;min-height:17px!important;width:100%!important;color:inherit!important}
    @media(prefers-reduced-motion:reduce){.nook-feed-collapsing{transition:none!important}}
  `;
  (document.head || document.documentElement).append(style);
  const seenObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) if (entry.isIntersecting) {
      const state = states.get(entry.target);
      if (state) state.seen = true;
    }
  });
  const restore = (state) => {
    state.node.classList.remove('nook-feed-hidden', 'nook-feed-merged', 'nook-feed-open', 'nook-feed-collapsing', 'nook-feed-fold');
    state.node.style.removeProperty('--nook-feed-height');
    if (state.onTransition) state.node.removeEventListener('transitionend', state.onTransition);
    state.onTransition = null;
    state.strip?.remove(); state.strip = null; state.renderKey = '';
  };
  const clear = () => {
    generation++; queue.clear(); cache.clear(); pending.clear();
    for (const state of states.values()) { restore(state); seenObserver.unobserve(state.node); }
    states.clear();
  };
  const decide = (state, decision) => {
    if (state.override || !state.node.isConnected) return;
    state.reason = (decision.reason || 'Hidden by your feed preferences').slice(0, 500);
    state.hidden = decision.choice === 'hide';
    if (!state.hidden) return;
    if (!counted.has(state.post.id)) {
      hiddenCount++;
      if (!decision.fixed) judgedCount++;
      const reason = state.reason.slice(0, 240);
      const key = reasons.has(reason) || reasons.size < 31 ? reason : 'Other feed preferences';
      reasons.set(key, (reasons.get(key) || 0) + 1);
      boundedSet(counted, state.post.id, true);
    }
    // Pending posts remain visible. A post that was seen folds rather than disappearing.
    const rect = state.node.getBoundingClientRect();
    state.seen ||= rect.top < innerHeight && rect.bottom > 0;
    if (state.seen && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
      const height = rect.height;
      state.node.style.setProperty('--nook-feed-height', `${height}px`);
      state.node.classList.add('nook-feed-collapsing');
      state.onTransition = (event) => {
        if (event.target !== state.node || event.propertyName !== 'max-height' || !state.hidden || states.get(state.node) !== state) return;
        state.node.removeEventListener('transitionend', state.onTransition); state.onTransition = null;
        state.node.classList.remove('nook-feed-collapsing', 'nook-feed-fold');
        state.node.classList.add('nook-feed-hidden');
      };
      state.node.addEventListener('transitionend', state.onTransition);
      requestAnimationFrame(() => requestAnimationFrame(() => {
        if (state.hidden && states.get(state.node) === state) state.node.classList.add('nook-feed-fold');
      }));
    } else state.node.classList.add('nook-feed-hidden');
  };
  const act = async (type, state) => {
    const current = generation;
    const result = await bridge({ type, post: state.post, reason: state.reason });
    if (type === 'mute' && !result.ok) return;
    if (type === 'mute') {
      if (!config.enabled || !adapter.active()) return;
      for (const [id, author] of overrides) if (handle(author) === handle(state.post.author)) overrides.delete(id);
      config.rules.mutedAccounts ||= [];
      if (!config.rules.mutedAccounts.includes(state.post.author)) config.rules.mutedAccounts.push(state.post.author);
      cache.clear();
      for (const item of states.values()) if (handle(item.post.author) === handle(state.post.author)) {
        item.override = false;
        if (!item.hidden) decide(item, { choice: 'hide', reason: 'Muted account', fixed: true });
      }
    } else {
      if (generation !== current || states.get(state.node) !== state) return;
      boundedSet(overrides, state.post.id, state.post.author);
      state.override = true; state.hidden = false; restore(state);
      boundedSet(cache, state.post.id, { choice: 'show', reason: '', override: true });
    }
    render();
  };
  const render = () => {
    const ordered = [...states.values()].filter((s) => s.node.isConnected).sort((a, b) =>
      a.node === b.node ? 0 : a.node.compareDocumentPosition(b.node) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
    let group = [];
    const draw = () => {
      if (!group.length) return;
      const leader = group[0];
      for (const state of group.slice(1)) {
        state.node.classList.add('nook-feed-merged'); state.strip?.remove(); state.strip = null; state.renderKey = '';
      }
      leader.node.classList.remove('nook-feed-merged');
      const key = group.map((s) => `${s.post.id}:${s.reason}`).join('|');
      if (leader.strip && leader.renderKey === key) return;
      leader.strip?.remove();
      const strip = document.createElement('nook-feed-strip');
      const shadow = strip.attachShadow({ mode: 'closed' });
      const css = document.createElement('style');
      css.textContent = `:host{font:11px -apple-system,BlinkMacSystemFont,sans-serif;color:inherit}button{font:inherit;color:inherit;background:transparent;border:0;cursor:pointer;padding:0 6px}button:hover{text-decoration:underline}button:focus-visible{outline:2px solid currentColor} .summary{display:block;width:100%;height:17px;text-align:left;opacity:.42;padding:0 12px} .summary:hover,.summary:focus-visible{opacity:.85}.details{padding:3px 12px 8px}.row{display:flex;flex-wrap:wrap;gap:5px;padding:5px 0;line-height:1.4}.reason{flex:1;min-width:100px;overflow-wrap:anywhere;opacity:.7}`;
      shadow.append(css);
      const toggle = document.createElement('button');
      toggle.className = 'summary'; toggle.type = 'button'; toggle.textContent = `${group.length} hidden`;
      toggle.setAttribute('aria-expanded', 'false');
      const details = document.createElement('div'); details.className = 'details'; details.hidden = true;
      const members = [...group];
      toggle.onclick = (e) => {
        e.preventDefault(); e.stopPropagation();
        details.hidden = !details.hidden;
        leader.node.classList.toggle('nook-feed-open', !details.hidden);
        // Opening a group must also finish an in-progress collapse.
        leader.node.classList.remove('nook-feed-collapsing', 'nook-feed-fold');
        leader.node.classList.add('nook-feed-hidden');
        toggle.setAttribute('aria-expanded', String(!details.hidden));
      };
      for (const state of members) {
        const row = document.createElement('div'); row.className = 'row';
        const label = document.createElement('span'); label.className = 'reason';
        label.textContent = `${state.post.author || 'Post'} · ${state.reason}`; row.append(label);
        for (const [type, title] of [['show', 'Show'], ['wrong', 'Wrong'], ['mute', 'Mute author']]) {
          if (type === 'mute' && !state.post.author) continue;
          const button = document.createElement('button'); button.type = 'button'; button.textContent = title;
          button.onclick = (e) => { e.preventDefault(); e.stopPropagation(); act(type, state); };
          row.append(button);
        }
        details.append(row);
      }
      shadow.append(toggle, details);
      leader.node.prepend(strip); leader.strip = strip; leader.renderKey = key;
    };
    for (const state of ordered) {
      if (!state.hidden || (group.length && state.node.parentElement !== group[0].node.parentElement)) { draw(); group = []; }
      if (state.hidden) group.push(state);
    }
    draw(); publish();
  };
  const flush = async () => {
    if (sending || !queue.size || !config.enabled || !config.judgeEnabled) return;
    const current = generation;
    const batch = [...queue.values()].slice(0, 20);
    batch.forEach((p) => { queue.delete(p.id); pending.add(p.id); });
    sending = true;
    try {
      const result = await bridge({ type: 'batch', posts: batch });
      if (generation !== current) return;
      const answers = new Map((Array.isArray(result) ? result : []).map((d) => [d.id, d]));
      for (const post of batch) {
        pending.delete(post.id);
        const decision = answers.get(post.id) || { id: post.id, choice: 'show', reason: '' };
        boundedSet(cache, post.id, decision);
        for (const state of states.values()) if (state.post.id === post.id && !state.decided) {
          state.decided = true; decide(state, decision);
        }
      }
      render();
    } finally { sending = false; schedule(); }
  };
  const scan = () => {
    if (route !== location.href) navigate();
    if (!config.enabled || !adapter.active()) return;
    for (const [node, state] of states) if (!node.isConnected) {
      restore(state); seenObserver.unobserve(node); states.delete(node);
    }
    for (const root of roots) for (const candidate of root.querySelectorAll(adapter.posts)) {
      const item = adapter.extract(candidate);
      if (!item || !item.post.text) continue;
      item.post.text = item.post.text.slice(0, 6000); item.post.author = item.post.author.slice(0, 256);
      let state = states.get(item.node);
      if (state && state.post.id !== item.post.id) {
        restore(state); seenObserver.unobserve(item.node); states.delete(item.node); state = null;
      }
      if (!state) {
        // Keep a window around the viewport, including posts that can be judged before arrival.
        const rect = item.node.getBoundingClientRect();
        if (rect.bottom < -innerHeight * 3 || rect.top > innerHeight * 8 || states.size >= LIMIT) continue;
        state = { ...item, hidden: false, seen: rect.top < innerHeight, decided: false, override: overrides.has(item.post.id), strip: null };
        states.set(item.node, state); seenObserver.observe(item.node);
      }
      if (state.decided || state.override) continue;
      const reason = fixedReason(state.post);
      const decision = reason ? (cache.get(state.post.id)?.choice === 'hide' ? cache.get(state.post.id) : { choice: 'hide', reason, fixed: true }) : cache.get(state.post.id);
      if (decision) {
        state.decided = true; state.override = decision.override || false;
        decide(state, decision); boundedSet(cache, state.post.id, decision);
      } else if (config.judgeEnabled && !pending.has(state.post.id) && queue.size < LIMIT) queue.set(state.post.id, state.post);
    }
    render(); flush();
  };
  // Two animation frames coalesce streaming cards without a timer or a polling loop.
  function schedule() {
    if (scheduled || !config.enabled) return;
    scheduled = true;
    requestAnimationFrame(() => requestAnimationFrame(() => { scheduled = false; scan(); }));
  }
  const disconnect = () => {
    observers.forEach((o) => o.disconnect()); observers = [];
    discovery?.disconnect(); discovery = null; roots = [];
  };
  const discover = () => {
    if (!config.enabled || !adapter.active()) return;
    const found = [...document.querySelectorAll(adapter.roots)].filter((node, i, all) => !all.some((other, j) => j !== i && other.contains(node)));
    if (!found.length) return;
    disconnect(); roots = found;
    for (const root of roots) {
      const observer = new MutationObserver((records) => {
        if (records.some((r) => r.type !== 'childList' || [...r.addedNodes, ...r.removedNodes].some((n) => n.nodeName !== 'NOOK-FEED-STRIP'))) schedule();
      });
      observer.observe(root, { childList: true, subtree: true, characterData: true, attributes: true,
        attributeFilter: ['href', 'id', 'data-fullname', 'author', 'post-title'] });
      observers.push(observer);
      // Shallow ancestor observers detect replacement of the feed or its mounting container.
      for (let ancestor = root.parentElement; ancestor; ancestor = ancestor.parentElement) {
        const parent = new MutationObserver(() => { if (!root.isConnected) { watch(); schedule(); } });
        parent.observe(ancestor, { childList: true }); observers.push(parent);
      }
    }
    schedule();
  };
  function watch() {
    disconnect();
    if (!config.enabled || !adapter.active()) return;
    discover();
    if (!roots.length) {
      // Discovery ends as soon as the feed mounts. Post extraction observes only feed roots.
      discovery = new MutationObserver(discover);
      discovery.observe(document.documentElement, { childList: true, subtree: true });
    }
  }
  function navigate() {
    if (route === location.href) return;
    summary(); clear(); overrides.clear(); counted.clear(); route = location.href;
    pageID = crypto.randomUUID(); bridge({ type: 'config' }).then(configure); watch();
  }
  function configure(next) {
    const key = JSON.stringify(next);
    if (key === configKey) return;
    configKey = key; clear(); config = next;
    config.rules ||= {}; watch(); schedule();
  }
  globalThis.nookFeedFilter = { configure, navigate };
  addEventListener('pagehide', () => { summary(); disconnect(); seenObserver.disconnect(); });
  addEventListener('pageshow', (event) => {
    if (event.persisted) {
      clear(); overrides.clear(); counted.clear(); pageID = crypto.randomUUID();
      bridge({ type: 'config' }).then(configure);
    }
    watch(); schedule();
  });
  addEventListener('popstate', navigate);
  addEventListener('scroll', schedule, { passive: true, capture: true });
  bridge({ type: 'config' }).then(configure);
})();
