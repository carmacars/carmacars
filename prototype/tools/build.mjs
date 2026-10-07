#!/usr/bin/env node
// Static build for the prototype. No dependencies.
//   node tools/build.mjs          writes every page file, the fleet data and dist/carmacars-prototype.html
// Pages are plain HTML files; this script only stamps the shared header, footer
// and photo manifest into them so they cannot drift apart.
import fs from 'node:fs';
import path from 'node:path';
import { CARS, RULES, PROTO_TODAY } from './src/data.mjs';
import { ROOT, PHOTOS } from './src/layout.mjs';
import { home, fleet, carPage } from './src/pages-main.mjs';
import { request, confirmation, owners, signin, contact, notFound } from './src/pages-flow.mjs';
import { how, requirements, delivery, faqPage, terms, privacy, cancellation } from './src/pages-info.mjs';
import { styleguide } from './src/styleguide.mjs';

const w = (f, s) => { fs.mkdirSync(path.dirname(path.join(ROOT, f)), { recursive: true }); fs.writeFileSync(path.join(ROOT, f), s); };
const r = (f) => fs.readFileSync(path.join(ROOT, f), 'utf8');

// ---- data for the browser
const fleetData = { _note: 'SAMPLE fleet for the prototype. Rules come from docs/source.', today: PROTO_TODAY, rules: RULES,
  cars: CARS.map((c) => ({ slug: c.slug, code: c.code, name: c.name, make: c.make, model: c.model, year: c.year, trim: c.trim, cls: c.cls, seats: c.seats, transmission: c.transmission, fuel: c.fuel, young: c.young, rates: c.rates, delivery: c.delivery, deposit: c.deposit, kmPerDay: c.kmPerDay, overage: c.overage, booked: c.booked, photo: PHOTOS.cars[c.slug].gallery[0].src })) };
w('assets/data/fleet.json', JSON.stringify(fleetData, null, 2) + '\n');
w('assets/js/fleet-data.js', '/* Generated from tools/src/data.mjs. SAMPLE DATA. */\nwindow.CC_FLEET = ' + JSON.stringify(fleetData) + ';\n');

// ---- pages
const pages = { 'index.html': home(), 'fleet.html': fleet(), 'request.html': request(), 'confirmation.html': confirmation(), 'owners.html': owners(), 'how-it-works.html': how(), 'requirements.html': requirements(), 'delivery.html': delivery(), 'faq.html': faqPage(), 'contact.html': contact(), 'terms.html': terms(), 'privacy.html': privacy(), 'cancellation.html': cancellation(), 'signin.html': signin(), '404.html': notFound(), 'styleguide.html': styleguide() };
for (const c of CARS) pages[`car-${c.slug}.html`] = carPage(c);
for (const [f, html] of Object.entries(pages)) {
  if (/[\u2013\u2014]/.test(html)) { const m = html.match(/.{30}[\u2013\u2014].{30}/); throw new Error(`Dash found in ${f}: ${m && m[0]}`); }
  w(f, html);
}
console.log(`pages written: ${Object.keys(pages).length}`);

// ---- single file
const b64 = (f) => fs.readFileSync(path.join(ROOT, f)).toString('base64');
let css = ['assets/css/tokens.css', 'assets/css/core.css', 'assets/css/pages.css'].map(r).join('\n');
css = css.replace(/url\("\.\.\/fonts\/([^"]+)"\)/g, (_, f) => `url("data:font/woff;base64,${b64('assets/fonts/' + f)}")`);
const photoMap = {};
const usePhoto = (src) => { if (!photoMap[src]) { const ext = path.extname(src).slice(1); const mime = { svg: 'image/svg+xml', jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp', avif: 'image/avif' }[ext]; photoMap[src] = `data:${mime};base64,${b64(src)}`; } return src; };
const rewrite = (html) => html
  .replace(/href="([a-z0-9-]+\.html)([^"]*)"/g, (_, p, rest) => { const [q, a] = rest.split('#'); return `href="#/${p}${q || ''}${a ? '~' + a : ''}"`; })
  .replace(/href="#([a-zA-Z][\w-]*)"/g, 'href="#$1" data-anchor="$1"')
  .replace(/ src="(assets\/photos\/[^"]+)"/g, (_, s) => ` data-src="${usePhoto(s)}"`)
  .replace(/ srcset="(assets\/photos\/[^"]+)"/g, (_, s) => ` data-srcset="${usePhoto(s)}"`);
const pick = (html, re) => (html.match(re) || [, ''])[1];
const views = Object.entries(pages).map(([f, html]) => {
  const main = pick(html, /<main id="main" tabindex="-1">([\s\S]*)<\/main>/);
  const ld = pick(html, /(<script type="application\/ld\+json">[\s\S]*?<\/script>)/);
  return `<template data-view="${f}" data-title="${pick(html, /<title>(.*?)<\/title>/)}" data-desc="${pick(html, /<meta name="description" content="(.*?)">/)}" data-body="${pick(html, /<body class="(.*?)">/)}">${rewrite(main)}${ld}</template>`;
}).join('\n');
const any = pages['index.html'];
const header = rewrite(pick(any, /<body class=".*?">([\s\S]*?)<main id="main"/));
const footer = rewrite(pick(any, /<\/main>([\s\S]*?<\/footer>)/));
const js = ['assets/js/fleet-data.js', 'assets/js/app.js', 'assets/js/pages.js'].map(r).join('\n;\n');
const router = r('tools/src/router.js');
const single = `<!doctype html>
<html lang="en-CA">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CarmaCars prototype</title>
<meta name="description" content="CarmaCars website prototype, single file.">
<meta name="robots" content="noindex">
<meta name="theme-color" content="#000000">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' fill='%23000'/%3E%3Cpath d='M9 22l3-12h11l-1.2 4H15l-.9 4h6.5L19.5 22z' fill='%23D0111B'/%3E%3C/svg%3E">
<style>${css}</style>
</head>
<body>
${header}
<main id="main" tabindex="-1"></main>
${footer}
${views}
<script>window.CC_SINGLE = true; window.CC_PHOTOS = ${JSON.stringify(photoMap)};</script>
<script>${js.replace(/<\/script/g, '<\\/script')}</script>
<script>${router}</script>
</body>
</html>
`;
w('dist/carmacars-prototype.html', single);
console.log(`single file: dist/carmacars-prototype.html ${(single.length / 1024 / 1024).toFixed(2)} MB, ${Object.keys(pages).length} views, ${Object.keys(photoMap).length} inlined images`);
