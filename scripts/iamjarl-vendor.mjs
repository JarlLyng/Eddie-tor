// IAMJARL design system v1.35.1: generated from tools/vendor.mjs, do not edit
// Takes one release of the IAMJARL design system into a static site, served
// from the site's own origin: the owner's rule since 1.32.2 (#100). It does in
// one command what the README's recipe does by hand, and what TonVault, Wean
// and It's 404 yo! each wrote a script of their own for.
//
//   node scripts/iamjarl-vendor.mjs v1.35.0 --root docs
//
// It reads the site's pages and takes only what they load:
//   1. the release, from GitHub's own archive of the tag, never jsDelivr
//      (or --from <dir>, a release already on disk);
//   2. every file the pages load from the design system, at jsDelivr or at an
//      older copy, copied to <root>/assets/iamjarl-design@vX.Y.Z/ in the
//      release's layout, with the fonts the font sheets name, each face's
//      licence, the store badges and the LICENSE;
//   3. every dist/ file checked against the tag's sri.json: on a mismatch it
//      stops before writing anything;
//   4. the pages pointed at the copy, each script and stylesheet with the tag's
//      integrity;
//   5. the generated pieces pasted again from the same tag, recognised by what
//      they are rather than by a comment: the store buttons, the nav's call to
//      action, the footer's cross-links, the Smart App Banner and the JSON-LD
//      offer;
//   6. older copies that no page loads any more, removed;
//   7. git asked to track the copy (a repo-wide `dist/` in .gitignore drops it),
//      and no page left loading the design system from jsDelivr.
//
// --check writes nothing and exits 1 if anything would change, for a site's CI.
// --base /static puts the copy somewhere other than /assets; --no-git skips 7;
// --self also replaces this script with the copy the release ships.
//
// No dependencies: Node 18 or later, and the system's tar.

import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : fallback; };
const flag = name => args.includes(`--${name}`);
const tag = args.find(a => /^v\d+\.\d+\.\d+$/.test(a));
if (!tag) {
  console.error('Usage: node iamjarl-vendor.mjs vX.Y.Z [--root <dir>] [--base /assets] [--from <dir>] [--check] [--no-git]');
  process.exit(2);
}
const ROOT = path.resolve(opt('root', '.'));
const BASE = '/' + opt('base', '/assets').replace(/^\/+|\/+$/g, '');
const COPY_URL = `${BASE}/iamjarl-design@${tag}`;
const COPY_DIR = path.join(ROOT, ...COPY_URL.split('/').filter(Boolean));
const CHECK = flag('check');

// Links into the design system: jsDelivr's copy of any tag, or a copy the site
// serves itself, at any tag, under any folder.
const DS = /(?:https:\/\/cdn\.jsdelivr\.net\/gh\/jarllyng\/iamjarl-design@v\d+\.\d+\.\d+|\/(?:[^"'\s,()]*\/)?iamjarl-design@v\d+\.\d+\.\d+)\/((?:dist|badges|fonts)\/[^"'\s,?#()]+)/gi;
const ON_CDN = /cdn\.jsdelivr\.net\/gh\/jarllyng\/iamjarl-design/i;

const sha384 = buf => `sha384-${crypto.createHash('sha384').update(buf).digest('base64')}`;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const fail = msg => { console.error(`✗ ${msg}`); process.exit(1); };

// 1. The release.
async function release() {
  if (opt('from')) return path.resolve(opt('from'));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'iamjarl-design-'));
  const url = `https://github.com/JarlLyng/iamjarl-design/archive/refs/tags/${tag}.tar.gz`;
  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(60000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      fs.writeFileSync(path.join(dir, 'release.tar.gz'), Buffer.from(await res.arrayBuffer()));
      break;
    } catch (err) {
      if (attempt === 5) fail(`could not download ${url}: ${err.message}`);
      await sleep(5000 * attempt);
    }
  }
  execFileSync('tar', ['-xzf', path.join(dir, 'release.tar.gz'), '--strip-components=1', '-C', dir]);
  return dir;
}

const SRC = await release();
const read = p => fs.readFileSync(path.join(SRC, p), 'utf-8');
const exists = p => fs.existsSync(path.join(SRC, p));
const tokens = JSON.parse(read('tokens.json'));
if (`v${tokens.meta.version}` !== tag) fail(`${SRC} is v${tokens.meta.version}, not ${tag}`);
const sri = JSON.parse(read('dist/sri.json'));
if (`v${sri.version}` !== tag) fail(`the release's sri.json is for v${sri.version}, not ${tag}`);
const registry = JSON.parse(read('apps.json'));
const storeApps = registry.apps.filter(a => a.store?.id);
// The app a store link points at: its store id is in the URL, App Store or Chrome Web Store.
const appOfLink = url => storeApps.find(a => String(url).includes(String(a.store.id)));

// The site's pages, leaving out every copy of the design system.
function pagesIn(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith('.') || e.name === 'node_modules' || /^iamjarl-design@v/.test(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...pagesIn(p));
    else if (e.name.endsWith('.html')) out.push(p);
  }
  return out;
}

// Where a match sits: the indentation of its line, so a pasted piece keeps it.
function indentAt(s, i) {
  const start = s.lastIndexOf('\n', i - 1) + 1;
  const before = s.slice(start, i);
  return /^[ \t]*$/.test(before) ? before : before.match(/^[ \t]*/)[0];
}
const reindent = (text, pad) => text.split('\n').map((l, k) => (k === 0 || !l ? l : pad + l)).join('\n');
// A generated piece: its first line is the "generated, do not edit" comment.
const piece = file => {
  if (!exists(file)) fail(`${tag} has no ${file}`);
  const lines = read(file).trimEnd().split('\n');
  return { head: lines[0], body: lines.slice(1).join('\n') };
};
const fragmentName = (id, code, placement, tone) => [id, code, placement === 'hero' ? null : placement, tone].filter(Boolean).join('.') + '.html';

// 4 and 5, for one page's HTML. Returns the new HTML and what it pasted.
function rework(html) {
  const pasted = [];
  const storeButtons = new Map(); // app id -> locales on this page

  // The store buttons. A fragment's <div> holds no other <div>.
  html = html.replace(/(<!-- IAMJARL store button for [^\n]*?-->[ \t]*\n[ \t]*)?<div class="ij-store" data-ij-store="([^"]+)" data-ij-store-locale="([^"]+)">[\s\S]*?<\/div>/g,
    (m, head, id, code, offset, s) => {
      const placement = (m.match(/data-umami-event-placement="([^"]+)"/) || [])[1] || 'hero';
      // No <picture>: a fixed tone, read from the badge. The Chrome Web Store's
      // white badge is the bordered one.
      const badge = (m.match(/badges\/([^"]+)"/) || [])[1] ?? '';
      const tone = m.includes('<picture') ? undefined
        : badge.startsWith('chrome-web-store') ? (badge.includes('border') ? 'white' : 'black')
        : (badge.match(/-(black|white)-/) || [])[1];
      const f = piece(`dist/store/${fragmentName(id, code, placement, tone)}`);
      (storeButtons.get(id) ?? storeButtons.set(id, new Set()).get(id)).add(code);
      pasted.push(`store button ${fragmentName(id, code, placement, tone)}`);
      const pad = indentAt(s, offset);
      return reindent(head ? `${f.head}\n${f.body}` : f.body, pad);
    });

  // The nav's call to action: only the generated one, by its click event.
  html = html.replace(/(<!-- IAMJARL nav call to action for [^\n]*?-->[ \t]*\n[ \t]*)?<a slot="cta" href="([^"]+)"[^>]*data-umami-event="store-click"[^>]*data-umami-event-placement="nav"[^>]*data-umami-event-locale="([^"]+)"[^>]*>[^<]*<\/a>/g,
    (m, head, href, code, offset, s) => {
      const app = appOfLink(href);
      if (!app) return m;
      const f = piece(`dist/store/${app.id}.${code}.nav.html`);
      pasted.push(`nav ${app.id}.${code}`);
      return reindent(head ? `${f.head}\n${f.body}` : f.body, indentAt(s, offset));
    });

  // The footer's cross-links, from their comment to the last link.
  html = html.replace(/<!-- IAMJARL cross-links for [^\n]*-->(?:\n[ \t]*<!--[^\n]*-->)*(?:\n[ \t]*<a slot="cross-links"[^\n]*<\/a>)+/g,
    (m, offset, s) => {
      const footer = s.slice(0, offset).match(/<ij-footer[^>]*\bapp="([^"]+)"[^>]*>(?![\s\S]*<ij-footer)/);
      if (!footer) return m;
      const file = `dist/footers/${footer[1]}.html`;
      if (!exists(file)) fail(`${tag} has no ${file}`);
      pasted.push(`cross-links ${footer[1]}`);
      return reindent(read(file).trimEnd(), indentAt(s, offset));
    });

  // The Smart App Banner.
  html = html.replace(/(<!-- Smart App Banner for [^\n]*?-->[ \t]*\n[ \t]*)?<meta name="apple-itunes-app" content="app-id=(\d+)[^"]*">/g,
    (m, head, storeId, offset, s) => {
      const app = appOfLink(`id${storeId}`);
      if (!app || !exists(`dist/store/${app.id}.head.html`)) return m;
      const f = piece(`dist/store/${app.id}.head.html`);
      pasted.push(`banner ${app.id}`);
      return reindent(head ? `${f.head}\n${f.body}` : f.body, indentAt(s, offset));
    });

  // The JSON-LD offer for an app whose store button is on the page.
  html = html.replace(/(<script type="application\/ld\+json">)([\s\S]*?)(<\/script>)/g, (m, open, json, close, offset, s) => {
    let data;
    try { data = JSON.parse(json); } catch { return m; }
    let changed = false;
    const visit = node => {
      if (Array.isArray(node)) return node.forEach(visit);
      if (!node || typeof node !== 'object') return;
      const o = node.offers;
      const app = o && typeof o === 'object' && !Array.isArray(o) && o.url && appOfLink(o.url);
      const codes = app && [...(storeButtons.get(app.id) ?? [])];
      if (codes && codes.length === 1) {
        const next = JSON.parse(read(`dist/store/${app.id}.${codes[0]}.offer.json`));
        if (JSON.stringify(next) !== JSON.stringify(o)) { node.offers = next; changed = true; pasted.push(`offer ${app.id}.${codes[0]}`); }
      }
      Object.values(node).forEach(visit);
    };
    visit(data);
    if (!changed) return m;
    // Keep the block's indentation: the <script> line's, and the step its keys use.
    const outer = indentAt(s, offset);
    const first = (json.match(/\n([ \t]*)"/) || [, `${outer}  `])[1];
    const step = Math.max(2, first.length - outer.length);
    const body = JSON.stringify(data, null, step).split('\n').map(l => `${outer}${l}`).join('\n');
    return `${open}\n${body}\n${outer}${close}`;
  });

  // Every link into the design system, to the copy, with the tag's integrity
  // on each script and stylesheet.
  html = html.replace(/<(link|script|img|source)\b[^>]*>/gi, tagHtml => {
    if (!DS.test(tagHtml)) return tagHtml;
    DS.lastIndex = 0;
    let file;
    let next = tagHtml.replace(DS, (_, p) => { file ??= p; return `${COPY_URL}/${p}`; });
    const hash = sri.files[file];
    if (/^<(link|script)/i.test(next) && hash) {
      next = /\bintegrity="[^"]*"/.test(next) ? next.replace(/\bintegrity="[^"]*"/, `integrity="${hash}"`) : next.replace(/\s*\/?>$/, m2 => ` integrity="${hash}"${m2}`);
    }
    return next;
  });

  // A preconnect to jsDelivr is pointless once nothing loads from it.
  if (!/cdn\.jsdelivr\.net/i.test(html.replace(/<link[^>]*rel="(?:preconnect|dns-prefetch)"[^>]*>/gi, ''))) {
    html = html.replace(/[ \t]*<link[^>]*rel="(?:preconnect|dns-prefetch)"[^>]*href="https:\/\/cdn\.jsdelivr\.net\/?"[^>]*>[ \t]*\n?/gi, '');
  }
  return { html, pasted };
}

// Read every page and work out the new one.
const pages = pagesIn(ROOT).map(file => {
  const before = fs.readFileSync(file, 'utf-8');
  const { html, pasted } = rework(before);
  return { file, before, html, pasted };
});
if (!pages.some(p => p.html.includes(`${COPY_URL}/`))) fail(`no page under ${ROOT} loads anything from the design system`);

// 2 and 3: what the pages load, and what that brings with it.
const wanted = new Set(['LICENSE']);
for (const p of pages) {
  for (const m of p.html.matchAll(new RegExp(`${COPY_URL.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/((?:dist|badges|fonts)/[^"'\\s,?#()]+)`, 'g'))) wanted.add(m[1]);
}
for (const f of [...wanted].filter(f => /^dist\/fonts\/[^/]+\.css$/.test(f))) {
  const face = path.basename(f, '.css');
  for (const m of read(f).matchAll(/url\(['"]?\.\.\/\.\.\/(fonts\/[^'")]+)['"]?\)/g)) wanted.add(m[1]);
  if (exists(`fonts/LICENSE-${face}.txt`)) wanted.add(`fonts/LICENSE-${face}.txt`);
}
const copy = [...wanted].sort();
for (const f of copy) {
  if (!exists(f)) fail(`a page loads ${f}, which ${tag} doesn't ship`);
  if (f.startsWith('dist/') && sri.files[f] && sha384(fs.readFileSync(path.join(SRC, f))) !== sri.files[f]) fail(`${f} doesn't match ${tag}'s sri.json`);
}

// 6: older copies no page loads any more.
const allHtml = pages.map(p => p.html).join('\n');
const stale = [];
(function findCopies(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!e.isDirectory() || e.name === 'node_modules' || e.name.startsWith('.')) continue;
    const p = path.join(dir, e.name);
    if (/^iamjarl-design@v\d+\.\d+\.\d+$/.test(e.name)) {
      if (p !== COPY_DIR && !allHtml.includes(`/${e.name}/`)) stale.push(p);
    } else findCopies(p);
  }
})(ROOT);

const changedPages = pages.filter(p => p.html !== p.before);
const copyIsCurrent = copy.every(f => fs.existsSync(path.join(COPY_DIR, f)) &&
  fs.readFileSync(path.join(COPY_DIR, f)).equals(fs.readFileSync(path.join(SRC, f))));
const rel = p => path.relative(process.cwd(), p) || '.';

if (CHECK) {
  const problems = [
    ...(copyIsCurrent ? [] : [`${rel(COPY_DIR)} is missing or differs from ${tag}`]),
    ...changedPages.map(p => `${rel(p.file)} would change: ${[...new Set(p.pasted)].join(', ') || 'links'}`),
    ...stale.map(d => `${rel(d)} is no longer loaded`),
    ...pages.filter(p => ON_CDN.test(p.html)).map(p => `${rel(p.file)} loads the design system from jsDelivr`),
  ];
  if (problems.length) { problems.forEach(x => console.error(`✗ ${x}`)); process.exit(1); }
  console.log(`✓ the pages under ${rel(ROOT)} and their copy are current with ${tag}`);
  process.exit(0);
}

// Write: the copy, the pages, then the old copies go.
fs.rmSync(COPY_DIR, { recursive: true, force: true });
for (const f of copy) {
  fs.mkdirSync(path.dirname(path.join(COPY_DIR, f)), { recursive: true });
  fs.copyFileSync(path.join(SRC, f), path.join(COPY_DIR, f));
  console.log(`  ${f.startsWith('dist/') && sri.files[f] ? 'ok ' : '   '}${f}`);
}
for (const p of changedPages) {
  fs.writeFileSync(p.file, p.html);
  console.log(`  ✎ ${rel(p.file)}${p.pasted.length ? `: ${[...new Set(p.pasted)].join(', ')}` : ''}`);
}
for (const d of stale) { fs.rmSync(d, { recursive: true, force: true }); console.log(`  − ${rel(d)}`); }

// 7. Nothing left on jsDelivr, and git takes all of the copy.
const onCdn = pages.filter(p => ON_CDN.test(p.html));
if (onCdn.length) fail(`still loading from jsDelivr: ${onCdn.map(p => rel(p.file)).join(', ')}`);
if (!flag('no-git')) {
  let inRepo = false;
  try { inRepo = execFileSync('git', ['rev-parse', '--is-inside-work-tree'], { cwd: ROOT, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim() === 'true'; } catch {}
  if (inRepo) {
    execFileSync('git', ['add', '--', COPY_DIR], { cwd: ROOT });
    const tracked = execFileSync('git', ['ls-files', '--', COPY_DIR], { cwd: ROOT }).toString().trim().split('\n').filter(Boolean).length;
    if (tracked !== copy.length) {
      let why = '';
      try { why = execFileSync('git', ['check-ignore', '-v', ...copy.map(f => path.join(COPY_DIR, f))], { cwd: ROOT }).toString(); } catch (e) { why = e.stdout?.toString() ?? ''; }
      fail(`git tracks ${tracked} of the copy's ${copy.length} files. An ignore rule drops the rest (anchor a build's \`dist/\` as \`/dist/\`):\n${why}`);
    }
  }
}

// Each release ships its own copy of this script; --self takes it.
const self = fileURLToPath(import.meta.url);
if (exists('dist/vendor.mjs') && read('dist/vendor.mjs') !== fs.readFileSync(self, 'utf-8')) {
  if (flag('self')) { fs.writeFileSync(self, read('dist/vendor.mjs')); console.log(`  ✎ ${rel(self)}: ${tag}'s copy of this script`); }
  else console.log(`\nNote: ${tag} ships a different copy of this script. Run again with --self to take it.`);
}
console.log(`\n✓ ${rel(ROOT)} loads iamjarl-design ${tag} from ${COPY_URL}: ${copy.length} files, ${changedPages.length} page(s) changed${stale.length ? `, ${stale.length} old copy removed` : ''}`);
