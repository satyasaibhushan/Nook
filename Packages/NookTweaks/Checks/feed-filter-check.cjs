// Licensed under GPL-3.0. See LICENSE.
// npm install --prefix /tmp/nook-feed-check-deps --no-save --package-lock=false --ignore-scripts jsdom
// NODE_PATH=/tmp/nook-feed-check-deps/node_modules node Packages/NookTweaks/Checks/feed-filter-check.cjs
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const source = fs.readFileSync(path.join(__dirname, '../Sources/NookTweaks/Resources/feed-filter.js'), 'utf8');
const fixture = (name) => fs.readFileSync(path.join(__dirname, `Fixtures/${name}.html`), 'utf8');
const settle = () => new Promise((resolve) => setImmediate(resolve));
async function setup(name, url, options = {}) {
  const dom = new JSDOM(fixture(name), { url, runScripts: 'outside-only' });
  const w = dom.window, messages = [], frames = [], shadows = new Map();
  let release;
  const deferred = new Promise((resolve) => { release = resolve; });
  const config = { enabled: true, judgeEnabled: true, rules: { mutedAccounts: ['@MUTED'], keywords: ['rage', ''] }, context: 'first', ...options.config };
  w.matchMedia = () => ({ matches: false });
  w.requestAnimationFrame = (fn) => { frames.push(fn); return frames.length; };
  w.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} };
  w.HTMLElement.prototype.getBoundingClientRect = () => ({ top: options.seen ? 10 : 2000, bottom: 2200, height: 200 });
  const attach = w.Element.prototype.attachShadow;
  w.Element.prototype.attachShadow = function (...args) { const shadow = attach.apply(this, args); shadows.set(this, shadow); return shadow; };
  w.webkit = { messageHandlers: { nookFeed: { postMessage: async (body) => {
    messages.push(body);
    if (body.type === 'config') return config;
    if (body.type === 'batch') {
      if (options.deferred) await deferred;
      if (options.fail) throw new Error('Unavailable');
      return body.posts.map((post) => ({ id: post.id, choice: options.hide ? 'hide' : 'show', reason: 'Off your preferences' }));
    }
    return { ok: true };
  } } } };
  w.eval(source);
  const drain = async (limit = 30) => {
    for (let i = 0; i < limit; i++) {
      await settle();
      const current = frames.splice(0);
      current.forEach((fn) => fn());
      if (!frames.length) { await settle(); if (!frames.length) return; }
    }
    throw new Error('Animation frames did not settle');
  };
  await drain();
  return { dom, w, messages, shadows, config, release, drain, close: () => dom.window.close() };
}
(async () => {
  for (const [name, url, total] of [
    ['x', 'https://x.com/home', 4], ['x', 'https://x.com/search?q=swift', 4],
    ['youtube', 'https://www.youtube.com/', 5], ['youtube', 'https://www.youtube.com/watch?v=current', 5],
    ['reddit', 'https://www.reddit.com/', 4], ['reddit', 'https://www.reddit.com/r/popular/', 4],
    ['reddit', 'https://www.reddit.com/r/swift/new/', 4], ['old-reddit', 'https://old.reddit.com/r/swift/', 3]
  ]) {
    const page = await setup(name, url);
    try {
      const batches = page.messages.filter((m) => m.type === 'batch');
      const posts = batches.flatMap((m) => m.posts);
      assert.equal(posts.length, total - 2, url);
      assert(posts.every((p) => Object.keys(p).sort().join(',') === 'author,id,text'));
      assert(posts.every((p) => !/rage/i.test(p.text) && p.author.toLowerCase() !== '@muted' && p.author !== 'Muted'));
      assert.equal(page.w.document.querySelectorAll('.nook-feed-hidden').length, 2);
      assert.equal(page.w.document.querySelectorAll('.nook-feed-merged').length, 1);
      const strip = page.w.document.querySelector('nook-feed-strip');
      const shadow = page.shadows.get(strip);
      assert.equal(shadow.querySelector('.summary').textContent, '2 hidden');
      shadow.querySelector('.summary').click();
      assert.equal(shadow.querySelector('.details').hidden, false);
      assert.equal(shadow.querySelectorAll('.row').length, 2);
      assert.equal(page.messages.filter((m) => m.type === 'summary').length, 0);
      page.w.dispatchEvent(new page.w.Event('pagehide'));
      page.w.dispatchEvent(new page.w.Event('pagehide'));
      const summaries = page.messages.filter((m) => m.type === 'summary');
      assert.equal(summaries.length, 1); assert.equal(summaries[0].count, 2);
    } finally { page.close(); }
  }
  for (const url of ['https://example.com/home', 'https://x.com.evil.test/home', 'https://x.com/Builder/status/1', 'https://youtube.com/results', 'https://reddit.com/r/swift/comments/123/title/']) {
    const page = await setup('x', url);
    assert.equal(page.messages.filter((m) => m.type === 'batch').length, 0);
    assert.equal(page.w.document.querySelectorAll('.nook-feed-hidden').length, 0);
    if (!url.includes('x.com/') && !url.includes('youtube.com/') && !url.includes('reddit.com/')) assert.equal(page.messages.length, 0);
    page.close();
  }
  const pending = await setup('x', 'https://x.com/home', { deferred: true, hide: true, seen: true });
  assert.equal(pending.w.document.querySelectorAll('.nook-feed-collapsing').length, 2);
  assert.equal(pending.w.document.querySelector('[href$="/Builder/status/101"]').closest('[data-testid="cellInnerDiv"]').className, '');
  // Mutations during an in-flight request must not send the same post twice.
  pending.w.document.querySelector('[data-testid="tweetText"]').append(' More context');
  await pending.drain();
  assert.equal(pending.messages.filter((m) => m.type === 'batch').length, 1);
  pending.release(); await pending.drain();
  assert.equal(pending.w.document.querySelectorAll('.nook-feed-collapsing').length, 4);
  pending.close();
  const scrolled = await setup('x', 'https://x.com/home', { deferred: true, hide: true });
  scrolled.w.HTMLElement.prototype.getBoundingClientRect = () => ({ top: 10, bottom: 210, height: 200 });
  scrolled.release(); await scrolled.drain();
  assert.equal(scrolled.w.document.querySelectorAll('.nook-feed-collapsing').length, 2);
  scrolled.close();
  const failed = await setup('x', 'https://x.com/home', { fail: true });
  assert.equal(failed.w.document.querySelectorAll('.nook-feed-hidden').length, 2);
  failed.close();
  const disabled = await setup('x', 'https://x.com/home', { config: { enabled: false } });
  assert.equal(disabled.messages.filter((m) => m.type === 'batch').length, 0);
  assert.equal(disabled.w.document.querySelectorAll('.nook-feed-hidden').length, 0);
  disabled.close();
  const noKey = await setup('x', 'https://x.com/home', { config: { judgeEnabled: false } });
  assert.equal(noKey.messages.filter((m) => m.type === 'batch').length, 0);
  assert.equal(noKey.w.document.querySelectorAll('.nook-feed-hidden').length, 2);
  noKey.close();
  const actions = await setup('x', 'https://x.com/home');
  let shadow = actions.shadows.get(actions.w.document.querySelector('nook-feed-strip'));
  shadow.querySelector('.summary').click();
  [...shadow.querySelectorAll('button')].find((b) => b.textContent === 'Wrong').click();
  await actions.drain();
  assert.equal(actions.messages.filter((m) => m.type === 'wrong').length, 1);
  assert.equal(actions.w.document.querySelectorAll('.nook-feed-hidden').length, 1);
  actions.w.nookFeedFilter.configure({ ...actions.config, enabled: false });
  await actions.drain();
  assert.equal(actions.w.document.querySelectorAll('.nook-feed-hidden, nook-feed-strip').length, 0);
  actions.w.nookFeedFilter.configure({ ...actions.config, context: 'again' }); await actions.drain();
  // Reveal-once survives preference and focus-context updates on this page.
  assert.equal(actions.w.document.querySelectorAll('.nook-feed-hidden').length, 1);
  const recycled = actions.w.document.querySelector('[href="/Muted/status/103"]');
  recycled.setAttribute('href', '/Builder/status/999');
  recycled.closest('article').querySelector('[data-testid="tweetText"]').textContent = 'New recycled post';
  await actions.drain();
  assert(!recycled.closest('[data-testid="cellInnerDiv"]').classList.contains('nook-feed-hidden'));
  assert(actions.messages.filter((m) => m.type === 'batch').flatMap((m) => m.posts).some((p) => p.id === 'x:999'));
  // Same-document navigation flushes one aggregate and turns off extraction outside feeds.
  actions.w.history.pushState({}, '', '/Builder/status/999'); actions.w.nookFeedFilter.navigate(); await actions.drain();
  assert.equal(actions.w.document.querySelectorAll('.nook-feed-hidden').length, 0);
  assert.equal(actions.messages.filter((m) => m.type === 'summary').length, 1);
  actions.close();
  const large = await setup('x', 'https://x.com/home');
  const root = large.w.document.querySelector('section > div');
  for (let i = 0; i < 45; i++) {
    const node = large.w.document.createElement('div'); node.dataset.testid = 'cellInnerDiv';
    node.innerHTML = `<article data-testid="tweet"><a href="/Builder/status/${1000 + i}"><time>Today</time></a><div data-testid="tweetText">Useful post ${i}</div></article>`;
    root.append(node);
  }
  await large.drain(80);
  const batches = large.messages.filter((m) => m.type === 'batch');
  assert(batches.every((m) => m.posts.length <= 20));
  const ids = batches.flatMap((m) => m.posts.map((p) => p.id));
  assert.equal(new Set(ids).size, ids.length);
  assert.equal(ids.length, 47);
  large.close();
  const mute = await setup('x', 'https://x.com/home');
  shadow = mute.shadows.get(mute.w.document.querySelector('nook-feed-strip'));
  shadow.querySelector('.summary').click();
  [...shadow.querySelectorAll('button')].find((b) => b.textContent === 'Show').click();
  await mute.drain();
  assert.equal(mute.messages.filter((m) => m.type === 'show').length, 1);
  shadow = mute.shadows.get(mute.w.document.querySelector('nook-feed-strip'));
  shadow.querySelector('.summary').click();
  [...shadow.querySelectorAll('button')].find((b) => b.textContent === 'Mute author').click();
  await mute.drain();
  assert.equal(mute.messages.filter((m) => m.type === 'mute').length, 1);
  mute.close();
  const stale = await setup('x', 'https://x.com/home', { deferred: true, hide: true });
  stale.w.nookFeedFilter.configure({ ...stale.config, enabled: false });
  stale.release(); await stale.drain();
  assert.equal(stale.w.document.querySelectorAll('.nook-feed-hidden, .nook-feed-collapsing').length, 0);
  stale.close();
  const remount = await setup('x', 'https://x.com/home');
  const column = remount.w.document.querySelector('[data-testid="primaryColumn"]');
  const copy = column.cloneNode(true);
  // Use fresh site markup, without any injected UI or state classes.
  copy.innerHTML = new JSDOM(fixture('x')).window.document.querySelector('[data-testid="primaryColumn"]').innerHTML;
  column.replaceWith(copy); await remount.drain();
  assert.equal(remount.w.document.querySelectorAll('.nook-feed-hidden').length, 2);
  remount.close();
  console.log('Feed adapter checks passed: 8 listing routes, host/path exclusions, rules, pending visibility, fail-open, grouping, actions, recycling, navigation, batches');
})().catch((error) => { console.error(error); process.exitCode = 1; });
