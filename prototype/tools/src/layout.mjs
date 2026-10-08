// Shared page chrome and markup helpers for the static build.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CARS, money, TOKENS } from './data.mjs';
import { SITE as S } from './site.mjs';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const PHOTOS = JSON.parse(fs.readFileSync(path.join(ROOT, 'assets/photos.json'), 'utf8'));
export const SITE = S.url;
export const EMAIL = S.email;
export { S as SETTINGS };
export const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
export { money };

const ICONS = {
  arrow: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 10h13M11 4.5l5.5 5.5-5.5 5.5" fill="none" stroke="currentColor" stroke-width="2"/></svg>',
  left: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M12.5 4l-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2"/></svg>',
  right: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M7.5 4l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2"/></svg>',
  cal: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 5.5h14v11H3zM3 9h14M6.5 3v4M13.5 3v4" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>',
  filter: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 6h14M6 10h8M8.5 14h3" fill="none" stroke="currentColor" stroke-width="2"/></svg>'
};
export const icon = (n) => ICONS[n];

// ---------- photos (every image on the site comes through here) ----------
export function slotPic(key, { sizes = '100vw', eager = false, alt } = {}) {
  const p = PHOTOS.slots[key]; if (!p) throw new Error('No photo slot ' + key);
  const a = esc(alt ?? p.alt);
  return `<picture data-photo="${key}"><source media="(min-width: 48rem)" srcset="${p.wide.src}" width="${p.wide.width}" height="${p.wide.height}"><img src="${p.tall.src}" width="${p.tall.width}" height="${p.tall.height}" alt="${a}" sizes="${sizes}" ${eager ? 'fetchpriority="high" decoding="async"' : 'loading="lazy" decoding="async"'}></picture>`;
}
export const carShots = (slug) => PHOTOS.cars[slug].gallery;
export function carImg(slug, shot = 'lead', { eager = false, alt, sizes = '(min-width: 64rem) 33vw, 100vw' } = {}) {
  const g = carShots(slug).find((x) => x.shot === shot) || carShots(slug)[0];
  return `<img data-photo="${slug}.${g.shot}" src="${g.src}" width="${g.width}" height="${g.height}" alt="${esc(alt ?? g.alt)}" sizes="${sizes}" ${eager ? 'fetchpriority="high" decoding="async"' : 'loading="lazy" decoding="async"'}>`;
}

// ---------- small components ----------
export const plate = (code, cls = '') => `<span class="plate ${cls}">${code}</span>`;
export function carCard(c, { i = 0, tag = 'h3' } = {}) {
  return `<article class="car-card">
    <div class="car-card__media photo photo--32">${carImg(c.slug, 'lead')}${plate(c.code)}<span class="badge badge--hatch car-card__flag" data-flag hidden>Booked for your dates</span></div>
    <div class="car-card__body">
      <${tag} class="car-card__name"><a href="car-${c.slug}.html">${c.make} <span>${c.model}</span></a></${tag}>
      <p class="car-card__meta">${c.year} ${c.trim}</p>
      <p class="car-card__price"><b class="num" data-price>${money(c.rates.daily)}</b><span data-unit>a day</span></p>
      <ul class="car-card__specs"><li>${c.cls}</li><li>${c.seats} seats</li><li>${c.transmission}</li><li>${c.fuel}</li>${c.young ? '<li class="strong">Ages {{minAge}}+</li>' : ''}</ul>
    </div>
  </article>`;
}
export const faq = (items) => `<div class="faq">${items.map(([q, a]) => `<details><summary>${q}</summary><div class="faq__a">${/^</.test(a.trim()) ? a : `<p>${a}</p>`}</div></details>`).join('')}</div>`;
export const faqLd = (items) => ({ '@type': 'FAQPage', mainEntity: items.map(([q, a]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() } })) });
export function crumbs(trail) { // [[label, href], ..., [label]]
  return `<nav class="crumbs" aria-label="Breadcrumb"><ol>${trail.map(([l, h], i) => i < trail.length - 1 ? `<li><a href="${h}">${l}</a></li>` : `<li><span aria-current="page">${l}</span></li>`).join('')}</ol></nav>`;
}
export const crumbsLd = (trail, file) => ({ '@type': 'BreadcrumbList', itemListElement: trail.map(([l, h], i) => ({ '@type': 'ListItem', position: i + 1, name: l, item: SITE + (h ?? file).replace(/^index\.html$/, '') })) });
export function dateRange({ id, label = true } = {}) {
  return `<div class="daterange" data-daterange>
      <div class="daterange__btns">
        <div><span class="label" id="${id}-l1">Pickup date</span><button type="button" class="datefield is-empty" data-dr="from" data-empty="Add date" aria-labelledby="${id}-l1 ${id}-v1"><span id="${id}-v1">Add date</span>${icon('cal')}</button></div>
        <div><span class="label" id="${id}-l2">Return date</span><button type="button" class="datefield is-empty" data-dr="to" data-empty="Add date" aria-labelledby="${id}-l2 ${id}-v2"><span id="${id}-v2">Add date</span>${icon('cal')}</button></div>
      </div>
      <input type="hidden" name="from"><input type="hidden" name="to">
      <div class="popover" role="dialog" aria-label="Choose pickup and return dates" hidden>
        <div data-cal></div>
        <div class="popover__foot"><button type="button" class="btn btn--quiet btn--sm" data-dr-clear>Clear dates</button><button type="button" class="btn btn--sm" data-dr-done>Done</button></div>
      </div>
    </div>`;
}
export const timeSelect = (name, label, id, def) => `<div class="field"><label class="label" for="${id}">${label}</label><select class="select" id="${id}" name="${name}" data-times="${def}"></select></div>`;

// ---------- chrome ----------
const NAV = [['fleet.html', 'Fleet', 'Every car, with dates and prices'], ['how-it-works.html', 'How it works', 'Request to book'], ['delivery.html', 'Delivery', '{{delMin}} to {{delMax}} each way'], ['requirements.html', 'Requirements', 'Age, licence, coverage'], ['owners.html', 'List your car', 'Owner program'], ['faq.html', 'FAQ', 'Straight answers']];
// Logo slot: an image if Admin > Settings has one, otherwise the text wordmark.
const mark = (dark) => { const img = (dark && S.logo.imageOnDark) || S.logo.image; return img ? `<img src="${img}" width="${S.logo.width}" height="${S.logo.height}" alt="${esc(S.logo.alt)}">` : 'Carma<b>Cars</b>'; };
export const wordmark = (cls = '', tag = 'a', dark = true) => tag === 'a'
  ? `<a class="wordmark ${cls}" href="index.html" aria-label="${S.brand} home">${mark(dark)}</a>`
  : `<span class="wordmark ${cls}" aria-hidden="true">${mark(dark)}</span>`;
// A site setting, or a hatched "to be added" marker when the owner has not confirmed it yet.
export const setting = (v, label) => (v ? esc(v) : `<span class="tbc">${label} to be added</span>`);
const socials = () => { const l = Object.entries(S.social).filter(([, u]) => u); return l.length ? `<li class="footer-social">${l.map(([n, u]) => `<a href="${u}" rel="noopener">${n[0].toUpperCase() + n.slice(1)}</a>`).join('')}</li>` : ''; };

export const header = () => `<a class="skip" href="#main">Skip to content</a>
<header class="site-header on-dark">
  <div class="wrap">
    ${wordmark()}
    <nav class="nav" aria-label="Main">${NAV.map(([h, l]) => `<a class="nav__link" href="${h}" data-nav="${h}">${l}</a>`).join('')}</nav>
    <div class="header-actions">
      <a class="btn btn--quiet btn--sm header-signin" href="signin.html" data-nav="signin.html">Sign in</a>
      <a class="btn btn--primary btn--sm" href="fleet.html">Find a car</a>
      <button type="button" class="menu-btn" aria-expanded="false" aria-controls="menu"><span>Menu</span><i aria-hidden="true"></i></button>
    </div>
  </div>
</header>
<div class="menu-panel on-dark" id="menu">
  <nav class="menu-panel__links" aria-label="Menu">${NAV.map(([h, l, s]) => `<a href="${h}" data-nav="${h}">${l}<span>${s}</span></a>`).join('')}<a href="contact.html" data-nav="contact.html">Contact<span>Talk to a person</span></a></nav>
  <div class="row"><a class="btn btn--light" href="signin.html">Sign in</a><a class="btn btn--primary" href="fleet.html">Find a car</a></div>
</div>`;

export const footer = () => `<footer class="site-footer on-dark">
  <div class="wrap">
    <div class="footer-grid">
      <div class="footer-cta stack">
        <p class="d3">{{tagline}}</p>
        <p class="muted small measure">Car rental in {{city}}, picked up or delivered. Bring it back the way you got it, and so does your deposit.</p>
        <p><a class="btn btn--primary" href="fleet.html">Find a car</a></p>
      </div>
      <nav aria-label="Rent"><h2>Rent</h2><ul><li><a href="fleet.html">Fleet</a></li><li><a href="how-it-works.html">How it works</a></li><li><a href="requirements.html">Requirements and coverage</a></li><li><a href="delivery.html">Delivery</a></li><li><a href="request.html">Request to book</a></li></ul></nav>
      <nav aria-label="Cars"><h2>Cars</h2><ul>${CARS.slice(0, 6).map((c) => `<li><a href="car-${c.slug}.html">${c.name}</a></li>`).join('')}<li><a href="fleet.html">See every car</a></li></ul></nav>
      <nav aria-label="Company"><h2>{{brand}}</h2><ul><li><a href="owners.html">List your car</a></li><li><a href="faq.html">FAQ</a></li><li><a href="contact.html">Contact</a></li><li><a href="signin.html">Sign in</a></li>${socials()}</ul></nav>
      <nav aria-label="Legal"><h2>Legal</h2><ul><li><a href="terms.html">Terms of use</a></li><li><a href="privacy.html">Privacy policy</a></li><li><a href="cancellation.html">Cancellation policy</a></li><li><a href="styleguide.html">Style guide</a></li></ul></nav>
    </div>
    <div class="footer-legal"><span>{{brand}}. {{serviceArea}}, Canada.</span><span>Prices in Canadian dollars, before HST unless stated.</span></div>
    ${wordmark('wordmark--xl footer-mark', 'span')}
  </div>
</footer>`;

// Every {{token}} in a page is filled from tools/src/data.mjs (policy, fees) or tools/src/site.mjs (settings).
const ALL = { ...TOKENS, brand: S.brand, tagline: S.tagline, city: S.city, region: S.region, serviceArea: S.serviceArea, email: S.email || '', reply: S.replyWording };
export const fill = (html) => html.replace(/\{\{(\w+)\}\}/g, (m, k) => { if (!(k in ALL)) throw new Error('Unknown token ' + m); return ALL[k]; });

export function doc(o) { return fill(rawDoc(o)); }
function rawDoc({ file, title, desc, main, ld, bodyClass = '', extra = '', noindex = false }) {
  const graph = ld ? `<script type="application/ld+json">${JSON.stringify({ '@context': 'https://schema.org', '@graph': [].concat(ld) })}</script>` : '';
  return `<!doctype html>
<html lang="en-CA">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}">
${noindex ? '<meta name="robots" content="noindex">' : `<link rel="canonical" href="${SITE}${file === 'index.html' ? '' : file}">`}
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{{brand}}">
<meta name="theme-color" content="#000000">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' fill='%23000'/%3E%3Cpath d='M9 22l3-12h11l-1.2 4H15l-.9 4h6.5L19.5 22z' fill='%23D0111B'/%3E%3C/svg%3E">
<link rel="preload" href="assets/fonts/inter-display-700.woff" as="font" type="font/woff" crossorigin>
<link rel="stylesheet" href="assets/css/tokens.css">
<link rel="stylesheet" href="assets/css/core.css">
<link rel="stylesheet" href="assets/css/pages.css">
${graph}
</head>
<body class="${bodyClass}">
${header()}
<main id="main" tabindex="-1">
${main}
${extra}
</main>
${footer()}
<script src="assets/js/fleet-data.js" defer></script>
<script src="assets/js/app.js" defer></script>
<script src="assets/js/pages.js" defer></script>
<script>document.addEventListener('DOMContentLoaded', function () { CC.boot(); });</script>
</body>
</html>
`;
}
