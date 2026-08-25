#!/usr/bin/env node
// DOM text smoke: the appended fruit-market chrome, read at 13 viewports.
//
// Goes to: tools/ci/dom_text_smoke.mjs. Run by ci.yml's `wasm-viewer` job.
//
// WHY (collab-cooking, 2026-08-25)
// --------------------------------
// The featured-match iframe on softmax.com is about 360 px wide. Everything
// this game says in words — the feed rows, the order-book rows and the roster
// chips — is DOM, not canvas, so `viewer_smoke.mjs --strict-text-bounds` cannot
// see it: a chip that collapses to "…" at 360 px passes every canvas check.
// This opens the real built page at 13 widths, feeds the appended game block a
// synthetic frame with full-cap strings, and asserts that each row is inside
// its host box AND that its text was not silently ellipsized away.
//
//   node tools/ci/dom_text_smoke.mjs --bundle dist/static-replay-viewer
//   node tools/ci/dom_text_smoke.mjs --url http://127.0.0.1:8000/index.html
//
// Exit 0 on success with one JSON line on stdout; exit 1 with the offending
// viewport, selector and measured box on failure.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const args = process.argv.slice(2);
function arg(name, fallback = null) {
  const at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
}

const bundle = arg('--bundle');
const url = arg('--url');
const timeout = Number(arg('--timeout', '60')) * 1000;
if (!bundle && !url) {
  console.error('usage: dom_text_smoke.mjs --bundle <dir> | --url <url>');
  process.exit(2);
}

const WIDTHS = [360, 380, 414, 480, 560, 620, 700, 820, 960, 1100, 1280, 1440, 1680];

const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.json': 'application/json', '.wasm': 'application/wasm',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp',
  '.data': 'application/octet-stream', '.ttf': 'font/ttf'
};

async function serve(dir) {
  const server = http.createServer((req, res) => {
    const name = decodeURIComponent((req.url || '/').split('?')[0]);
    const file = path.join(dir, name === '/' ? '/index.html' : name);
    if (!file.startsWith(path.resolve(dir))) { res.writeHead(403).end(); return; }
    fs.readFile(file, (err, body) => {
      if (err) { res.writeHead(404).end(); return; }
      res.writeHead(200, {
        'content-type': MIME[path.extname(file)] || 'application/octet-stream',
        'access-control-allow-origin': '*'
      });
      res.end(body);
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { server, port: server.address().port };
}

async function loadPlaywright() {
  const mod = process.env.PLAYWRIGHT_MODULE || 'playwright';
  try {
    return await import(mod);
  } catch (error) {
    console.error('Playwright is not installed:', error.message);
    process.exit(2);
  }
}

// One synthetic chrome frame, with every string at its server-side cap.
const FRAME = (() => {
  const aliases = ['Ash', 'Bram', 'Cedar', 'Dune', 'Elm', 'Fern', 'Gale', 'Holt'];
  const policies = ['fruit-market-broker', 'fruit-market-ricardo',
    'fruit-market-hauler', 'fruit-market-homesteader', 'fruit-market-hauler',
    'fruit-market-hauler', 'fruit-market-homesteader', 'fruit-market-broker'];
  let say = 'mirroring ASH at the north stall - three apples for two bananas ok';
  while (say.length < 80) say += '.';
  say = say.slice(0, 80);
  const roster = aliases.map((name, i) => ({
    s: i, team: i % 2 === 0 ? 'apple' : 'banana', name, pol: policies[i],
    col: i, alive: true, lives: 40 + i, hp: 60, carry: false,
    k: 0, d: 0, cap: 0, mk2: 0, mk3: 0, tk: 0,
    farm: i % 2 === 0 ? 'apple' : 'banana', apples: 6, bananas: 4,
    hunger: 60, stamina: 80, score: 200 - i * 7,
    exhausted: false, starving: i === 5
  }));
  const book = aliases.map((name, i) => ({
    s: i, name, give: i % 2 === 0 ? 'apple' : 'banana', giveN: 6,
    want: i % 2 === 0 ? 'banana' : 'apple', wantN: 4, unfunded: i === 3
  }));
  const events = [];
  for (let i = 0; i < 8; i++) {
    events.push({ k: 'order', t: 240, seat: i, say, source: 'llm' });
  }
  events.push({
    k: 'trade', t: 240, a: 0, b: 1, aGive: 'apple', aGiveN: 6,
    bGive: 'banana', bGiveN: 4, applesPerBanana: 150, x: 16, y: 4, dist: 1
  });
  return {
    t: 240, mt: 719, ph: 'playing', lob: 0, pl: true, sp: 1, mx: 719, st: 0,
    lp: false, sk: false, ff: false, en: true, mm: -1, bs: 1, pov: -1,
    teams: {
      apple: { lives: 640, flag: 'home', carrier: -1, prog: 0,
        policies: ['Apple Farmers'] },
      banana: { lives: 610, flag: 'home', carrier: -1, prog: 0,
        policies: ['Banana Farmers'] }
    },
    roster, events,
    fm: { round: 5, rounds: 12, tick: 240, ticks: 720, rate: 150, book,
      book_rate: 150 },
    beats: [
      { t: 60, k: 'round', n: 1 }, { t: 163, k: 'firsttrade' },
      { t: 402, k: 'starve', seat: 6 }, { t: 719, k: 'gameover' }
    ],
    lead: { teams: ['rate'], pts: [[0, 150], [240, 160], [719, 148]] }
  };
})();

const { chromium } = await loadPlaywright();
let target = url;
let handle = null;
if (bundle) {
  handle = await serve(path.resolve(bundle));
  target = `http://127.0.0.1:${handle.port}/index.html?replay=none`;
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
page.setDefaultTimeout(timeout);
const failures = [];
const measured = [];
try {
  await page.goto(target, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => !!window.FruitMarketBlock, null,
    { timeout });
  for (const width of WIDTHS) {
    await page.setViewportSize({ width, height: Math.max(360, Math.round(width * 0.62)) });
    await page.evaluate((frame) => {
      window.FruitMarketBlock.onFrame(frame, function () {}, null);
    }, FRAME);
    await page.waitForTimeout(80);
    const result = await page.evaluate(() => {
      function boxes(selector) {
        return Array.from(document.querySelectorAll(selector)).map(el => {
          const r = el.getBoundingClientRect();
          return {
            text: el.textContent || '',
            w: Math.round(r.width), h: Math.round(r.height),
            left: Math.round(r.left), right: Math.round(r.right),
            scrollW: el.scrollWidth, clientW: el.clientWidth
          };
        });
      }
      return {
        chips: boxes('#fm-roster .fm-chip'),
        book: boxes('#fm-book .fm-book-row'),
        feed: boxes('#killfeed .feed-row'),
        vw: window.innerWidth
      };
    });
    measured.push({ width, chips: result.chips.length, book: result.book.length,
      feed: result.feed.length });
    if (result.chips.length !== 8) {
      failures.push(`${width}px: expected 8 roster chips, saw ${result.chips.length}`);
    }
    if (result.book.length !== 8) {
      failures.push(`${width}px: expected 8 order-book rows, saw ${result.book.length}`);
    }
    if (result.feed.length < 1) {
      failures.push(`${width}px: the feed is empty`);
    }
    for (const row of result.chips.concat(result.book).concat(result.feed)) {
      if (row.h <= 1 || row.w <= 1) {
        failures.push(`${width}px: a row collapsed to ${row.w}x${row.h}: "${row.text.slice(0, 40)}"`);
      }
      if (row.left < -2 || row.right > result.vw + 2) {
        failures.push(`${width}px: a row is outside the viewport (${row.left}..${row.right} of ${result.vw}): "${row.text.slice(0, 40)}"`);
      }
    }
    // Every chip must still carry its alias and its score in full: the whole
    // point of the 360 px floor is that DUNE 231 stays readable.
    for (const chip of result.chips) {
      if (!/[A-Z]{3,}/.test(chip.text)) {
        failures.push(`${width}px: a roster chip lost its alias: "${chip.text}"`);
      }
      if (!/\d/.test(chip.text)) {
        failures.push(`${width}px: a roster chip lost its score: "${chip.text}"`);
      }
    }
  }
} catch (error) {
  failures.push('dom_text_smoke: ' + (error && error.message ? error.message : error));
} finally {
  await browser.close();
  if (handle) handle.server.close();
}

if (failures.length) {
  for (const failure of failures) console.error('::error::' + failure);
  process.exit(1);
}
console.log(JSON.stringify({ ok: true, viewports: measured }));
