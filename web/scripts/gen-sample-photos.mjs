// The built-in sample photos (migration 0054): one clean, neutral placeholder per body type, in the CarmaCars style
// (grey studio, a charcoal side view, the red line of the brand), with "Sample photo" printed in the corner so a copy
// shared on its own still says what it is. A listing with no real photo shows the one for its body type until staff
// add real photos or a library photo (Admin > Settings > Sample photos).
//   node scripts/gen-sample-photos.mjs     writes public/sample-photos/<type>.svg and .jpg (1600 x 1067)
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '@playwright/test';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(WEB, 'public/sample-photos');
const W = 1600, H = 1067, GROUND = 800;

// Each body: the outline (side view, facing right), the glass, the wheels (x, radius) and an optional detail.
const BODIES = {
  sedan: { body: [[255, 790], [250, 700], [290, 640], [455, 605], [640, 470], [930, 465], [1085, 600], [1330, 640], [1372, 700], [1368, 790]],
    glass: [[505, 600], [660, 492], [905, 488], [1035, 598]], pillar: [[770, 490], [770, 600]], wheels: [[470, 96], [1150, 96]] },
  suv: { body: [[240, 790], [236, 590], [300, 420], [960, 410], [1100, 560], [1340, 600], [1380, 680], [1376, 790]],
    glass: [[300, 560], [345, 445], [935, 440], [1045, 560]], pillar: [[640, 445], [640, 560]], wheels: [[465, 108], [1150, 108]] },
  truck: { body: [[220, 790], [220, 600], [760, 600], [790, 440], [1060, 440], [1160, 590], [1370, 615], [1395, 690], [1390, 790]],
    glass: [[830, 580], [845, 468], [1035, 468], [1110, 580]], bed: [[230, 600], [750, 600]], wheels: [[450, 110], [1170, 110]] },
  van: { body: [[230, 790], [230, 380], [1040, 370], [1230, 560], [1360, 610], [1390, 690], [1385, 790]],
    glass: [[1010, 550], [1035, 410], [1095, 410], [1190, 550]], side: [[300, 430], [900, 430], [900, 560], [300, 560]], wheels: [[440, 100], [1170, 100]] },
  coupe: { body: [[280, 790], [270, 700], [330, 640], [560, 590], [760, 495], [960, 490], [1120, 610], [1350, 650], [1385, 705], [1380, 790]],
    glass: [[600, 590], [775, 515], [945, 512], [1060, 600]], wheels: [[490, 95], [1150, 95]] },
  hatchback: { body: [[300, 790], [295, 690], [330, 520], [420, 470], [850, 465], [1000, 600], [1250, 635], [1300, 700], [1296, 790]],
    glass: [[360, 590], [410, 500], [830, 495], [950, 595]], pillar: [[640, 497], [640, 592]], wheels: [[480, 96], [1100, 96]] },
  ev: { body: [[255, 790], [252, 700], [300, 635], [470, 600], [660, 470], [940, 462], [1110, 598], [1340, 640], [1380, 700], [1376, 790]],
    glass: [[515, 598], [680, 490], [915, 486], [1055, 596]], pillar: [[790, 488], [790, 598]], wheels: [[470, 96], [1155, 96]], ev: true }
};

const LABEL = { sedan: 'Sedan', suv: 'SUV', truck: 'Pickup truck', van: 'Van', coupe: 'Coupe', hatchback: 'Hatchback', ev: 'Electric car' };
const pts = (a) => a.map(([x, y]) => `${x},${y}`).join(' ');

function svg(type) {
  const b = BODIES[type];
  const wheels = b.wheels.map(([x, r]) => `
    <circle cx="${x}" cy="${GROUND - r + 6}" r="${r + 14}" fill="#e9e9ea"/>
    <circle cx="${x}" cy="${GROUND - r + 6}" r="${r}" fill="#151515"/>
    <circle cx="${x}" cy="${GROUND - r + 6}" r="${Math.round(r * 0.56)}" fill="#c9cacc"/>
    <circle cx="${x}" cy="${GROUND - r + 6}" r="${Math.round(r * 0.18)}" fill="#7b7c80"/>`).join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f7f7f7"/><stop offset="0.72" stop-color="#ececec"/><stop offset="1" stop-color="#dedede"/></linearGradient>
    <linearGradient id="paint" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4a4b4f"/><stop offset="1" stop-color="#26272a"/></linearGradient>
    <radialGradient id="shadow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#000" stop-opacity="0.28"/><stop offset="1" stop-color="#000" stop-opacity="0"/></radialGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#bg)"/>
  <rect x="0" y="${GROUND + 6}" width="${W}" height="${H - GROUND}" fill="#e2e2e3"/>
  <ellipse cx="${(b.wheels[0][0] + b.wheels[1][0]) / 2}" cy="${GROUND + 12}" rx="${(b.wheels[1][0] - b.wheels[0][0]) / 2 + 280}" ry="34" fill="url(#shadow)"/>
  <rect x="120" y="${GROUND + 40}" width="${W - 240}" height="6" fill="#D0111B"/>
  <polygon points="${pts(b.body)}" fill="url(#paint)" stroke="#26272a" stroke-width="26" stroke-linejoin="round"/>
  <polygon points="${pts(b.glass)}" fill="#a9b4bd" stroke="#a9b4bd" stroke-width="10" stroke-linejoin="round" opacity="0.92"/>
  ${b.pillar ? `<line x1="${b.pillar[0][0]}" y1="${b.pillar[0][1]}" x2="${b.pillar[1][0]}" y2="${b.pillar[1][1]}" stroke="#3a3b3f" stroke-width="16"/>` : ''}
  ${b.bed ? `<line x1="${b.bed[0][0]}" y1="${b.bed[0][1] + 12}" x2="${b.bed[1][0]}" y2="${b.bed[1][1] + 12}" stroke="#5b5c60" stroke-width="8"/>` : ''}
  ${b.side ? `<polygon points="${pts(b.side)}" fill="none" stroke="#5b5c60" stroke-width="6"/>` : ''}
  ${b.ev ? `<g transform="translate(${b.wheels[0][0] + 230}, 655)"><circle r="34" fill="#D0111B"/><path d="M6 -22 L-12 4 L0 4 L-6 24 L14 -4 L2 -4 Z" fill="#fff"/></g>` : ''}
  <line x1="${b.body[b.body.length - 1][0] - 20}" y1="${GROUND - 115}" x2="${b.body[b.body.length - 1][0] - 2}" y2="${GROUND - 115}" stroke="#f2f2f2" stroke-width="14" stroke-linecap="round"/>
  ${wheels}
  <g font-family="Arial, Helvetica, sans-serif">
    <rect x="48" y="${H - 104}" width="330" height="58" fill="#000" opacity="0.78"/>
    <text x="72" y="${H - 64}" font-size="30" font-weight="700" fill="#fff">Sample photo</text>
    <text x="${W - 48}" y="${H - 64}" font-size="28" font-weight="700" fill="#6b6c70" text-anchor="end">${LABEL[type]}</text>
  </g>
</svg>`;
}

mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: W, height: H } });
for (const type of Object.keys(BODIES)) {
  const s = svg(type);
  writeFileSync(path.join(OUT, `${type}.svg`), s);
  await page.setContent(`<!doctype html><html><body style="margin:0">${s}</body></html>`);
  await page.screenshot({ path: path.join(OUT, `${type}.jpg`), type: 'jpeg', quality: 82, clip: { x: 0, y: 0, width: W, height: H } });
}
await browser.close();
console.log(`sample photos: ${Object.keys(BODIES).join(', ')} in public/sample-photos`);
