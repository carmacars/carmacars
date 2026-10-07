#!/usr/bin/env node
// Draws the art-directed stand-in images (original SVG, no brand shapes) and
// writes assets/photos.json. Real photos replace these by file drop + manifest
// edit; any manifest entry with "standIn": false is preserved on re-run.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CARS } from './src/data.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'assets/photos');
fs.mkdirSync(OUT, { recursive: true });

const PAINT = {
  white: ['#F4F4F4', '#B9B9B9', '#6E6E6E'],
  silver: ['#D2D2D2', '#8C8C8C', '#4A4A4A'],
  grey: ['#8E8E8E', '#555555', '#262626'],
  black: ['#4A4A4A', '#1C1C1C', '#070707'],
  red: ['#EE3A42', '#C20F18', '#5C060A']
};

const SHAPES = {
  compact:  { x0: 70,  x1: 930, hh: 178, xc: 335, hc: 160, xr1: 452, hr: 97,  xr2: 630, xg: 792, hd: 148, wf: 222, wr: 762, r: 45, base: 262 },
  sedan:    { x0: 45,  x1: 955, hh: 180, xc: 335, hc: 161, xr1: 455, hr: 99,  xr2: 645, xg: 808, hd: 152, wf: 212, wr: 778, r: 46, base: 262 },
  fastback: { x0: 60,  x1: 940, hh: 178, xc: 345, hc: 160, xr1: 470, hr: 101, xr2: 600, xg: 838, hd: 150, wf: 218, wr: 770, r: 46, base: 262 },
  suv:      { x0: 70,  x1: 930, hh: 158, xc: 318, hc: 136, xr1: 420, hr: 62,  xr2: 735, xg: 872, hd: 124, wf: 222, wr: 762, r: 53, base: 252 },
  suvlg:    { x0: 45,  x1: 955, hh: 150, xc: 318, hc: 128, xr1: 425, hr: 50,  xr2: 760, xg: 898, hd: 116, wf: 215, wr: 780, r: 58, base: 250 },
  van:      { x0: 45,  x1: 955, hh: 166, xc: 255, hc: 142, xr1: 380, hr: 46,  xr2: 820, xg: 925, hd: 104, wf: 200, wr: 790, r: 48, base: 258 },
  roadster: { x0: 110, x1: 890, hh: 190, xc: 405, hc: 177, xr1: 478, hr: 128, xr2: 585, xg: 676, hd: 174, wf: 255, wr: 742, r: 44, base: 264 }
};

let uid = 0;
// Side profile, nose to the left. Local box 1000 x 320, ground line at y=308.
function carSide(shape, paint, { flip = false } = {}) {
  const s0 = SHAPES[shape]; const s = { ...s0 }; const [c1, c2, c3] = PAINT[paint]; const id = 'c' + (uid++);
  for (const k of ['x0', 'x1', 'xc', 'xr1', 'xr2', 'xg', 'wf', 'wr']) s[k] = 500 + (s0[k] - 500) * 0.8; // real-car proportions
  const G = 308; const wy = G - s.r; const a = s.r + 9; const b = s.base;
  const body = `M ${s.x0 + 22},${b}
    Q ${s.x0 - 6},${b - 4} ${s.x0},${b - 38}
    Q ${s.x0 + 2},${s.hh + 26} ${s.x0 + 46},${s.hh + 8}
    Q ${(s.x0 + s.xc) / 2},${s.hh - 14} ${s.xc},${s.hc}
    Q ${s.xc + (s.xr1 - s.xc) * 0.55},${s.hr + 8} ${s.xr1},${s.hr}
    Q ${(s.xr1 + s.xr2) / 2},${s.hr - 10} ${s.xr2},${s.hr + 4}
    Q ${s.xr2 + (s.xg - s.xr2) * 0.62},${s.hr + 16} ${s.xg},${s.hd}
    L ${s.x1 - 42},${s.hd + 5}
    Q ${s.x1 + 4},${s.hd + 12} ${s.x1},${s.hd + 54}
    L ${s.x1 - 2},${b - 28} Q ${s.x1 - 2},${b - 2} ${s.x1 - 26},${b}
    L ${s.wr + a},${b} A ${a} ${a} 0 0 0 ${s.wr - a},${b}
    L ${s.wf + a},${b} A ${a} ${a} 0 0 0 ${s.wf - a},${b} Z`;
  const belt = Math.max(s.hc, s.hd) + 6;
  const glass = `M ${s.xc + 22},${s.hc + 4}
    Q ${s.xc + (s.xr1 - s.xc) * 0.6},${s.hr + 20} ${s.xr1 + 8},${s.hr + 13}
    Q ${(s.xr1 + s.xr2) / 2},${s.hr + 4} ${s.xr2 - 6},${s.hr + 16}
    Q ${s.xr2 + (s.xg - s.xr2) * 0.6},${s.hr + 26} ${s.xg - 22},${s.hd + 2}
    L ${s.xc + 26},${belt} Z`;
  const pillar = (s.xr1 + s.xr2) / 2 + 8;
  const wheel = (x) => `<g transform="translate(${x} ${wy})"><circle r="${s.r}" fill="#050505"/><circle r="${s.r * 0.72}" fill="url(#${id}rim)"/><circle r="${s.r * 0.72}" fill="none" stroke="#000" stroke-width="2"/>${[0, 36, 72, 108, 144].map((d) => `<rect x="-3" y="${-s.r * 0.7}" width="6" height="${s.r * 1.4}" fill="#1b1b1b" transform="rotate(${d})"/>`).join('')}<circle r="${s.r * 0.17}" fill="#101010" stroke="#777" stroke-width="1.5"/></g>`;
  const inner = `
    <defs>
      <linearGradient id="${id}b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${c1}"/><stop offset=".45" stop-color="${c2}"/><stop offset="1" stop-color="${c3}"/></linearGradient>
      <linearGradient id="${id}g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5a5a5a"/><stop offset=".35" stop-color="#151515"/><stop offset="1" stop-color="#000"/></linearGradient>
      <radialGradient id="${id}rim"><stop offset="0" stop-color="#8a8a8a"/><stop offset=".7" stop-color="#5c5c5c"/><stop offset="1" stop-color="#2a2a2a"/></radialGradient>
      <linearGradient id="${id}s" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".3" stop-color="#fff" stop-opacity=".9"/><stop offset=".75" stop-color="#fff" stop-opacity=".55"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
    </defs>
    <ellipse cx="500" cy="${G + 2}" rx="${(s.x1 - s.x0) / 2 + 10}" ry="13" fill="#000" opacity=".85"/>
    <path d="${body}" fill="url(#${id}b)"/>
    <path d="${body}" fill="none" stroke="url(#${id}s)" stroke-width="2.2" stroke-linejoin="round" opacity=".8"/>
    <path d="M ${s.x0 + 24},${belt + 34} L ${s.x1 - 24},${belt + 26}" stroke="#fff" stroke-opacity=".16" stroke-width="2"/>
    <path d="M ${s.x0 + 40},${b - 14} L ${s.x1 - 40},${b - 14}" stroke="#000" stroke-opacity=".35" stroke-width="10"/>
    <path d="${glass}" fill="url(#${id}g)"/>
    <path d="M ${pillar},${s.hr + 8} L ${pillar + 6},${belt}" stroke="${c3}" stroke-width="9"/>
    <path d="M ${s.xc + 60},${belt + 14} h 38 M ${pillar + 40},${belt + 12} h 38" stroke="#000" stroke-opacity=".5" stroke-width="5" stroke-linecap="round"/>
    <path d="M ${s.x0 + 6},${s.hh + 30} q 18,-12 46,-14 l -4,12 q -22,2 -42,14 z" fill="#fff" opacity=".95"/>
    <path d="M ${s.x1 - 4},${s.hd + 20} q -20,-6 -44,-6 l 2,12 q 22,0 42,8 z" fill="#E0121C"/>
    ${wheel(s.wf)}${wheel(s.wr)}`;
  return flip ? `<g transform="translate(1000 0) scale(-1 1)">${inner}</g>` : inner;
}

// Head-on or tail-on view. Local box 600 x 320, ground at y=308.
function carEnd(shape, paint, rear) {
  const [c1, c2, c3] = PAINT[paint]; const id = 'e' + (uid++);
  const tall = shape === 'suv' || shape === 'suvlg' || shape === 'van'; const low = shape === 'roadster';
  const top = tall ? 40 : low ? 120 : 84; const sh = tall ? 130 : low ? 178 : 158; const w = tall ? 250 : 240; const cx = 300;
  return `<defs>
    <linearGradient id="${id}b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${c1}"/><stop offset=".5" stop-color="${c2}"/><stop offset="1" stop-color="${c3}"/></linearGradient>
    <linearGradient id="${id}g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4c4c4c"/><stop offset="1" stop-color="#050505"/></linearGradient></defs>
    <ellipse cx="${cx}" cy="310" rx="285" ry="11" fill="#000" opacity=".85"/>
    <rect x="${cx - w - 2}" y="236" width="62" height="72" rx="10" fill="#050505"/><rect x="${cx + w - 60}" y="236" width="62" height="72" rx="10" fill="#050505"/>
    <path d="M ${cx - w + 62},${sh} Q ${cx - w + 78},${top + 6} ${cx - w + 112},${top} L ${cx + w - 112},${top} Q ${cx + w - 78},${top + 6} ${cx + w - 62},${sh} Z" fill="url(#${id}b)"/>
    <path d="M ${cx - w + 80},${sh - 4} Q ${cx - w + 92},${top + 18} ${cx - w + 120},${top + 13} L ${cx + w - 120},${top + 13} Q ${cx + w - 92},${top + 18} ${cx + w - 80},${sh - 4} Z" fill="url(#${id}g)"/>
    <path d="M ${cx - w},${sh + 22} Q ${cx - w + 4},${sh - 2} ${cx - w + 50},${sh - 6} L ${cx + w - 50},${sh - 6} Q ${cx + w - 4},${sh - 2} ${cx + w},${sh + 22} L ${cx + w + 2},262 Q ${cx + w},284 ${cx + w - 30},284 L ${cx - w + 30},284 Q ${cx - w},284 ${cx - w - 2},262 Z" fill="url(#${id}b)"/>
    <path d="M ${cx - w + 4},${sh + 12} Q ${cx},${sh - 12} ${cx + w - 4},${sh + 12}" fill="none" stroke="#fff" stroke-opacity=".5" stroke-width="2"/>
    <rect x="${cx - w - 26}" y="${sh - 12}" width="34" height="18" rx="6" fill="${c2}"/><rect x="${cx + w - 8}" y="${sh - 12}" width="34" height="18" rx="6" fill="${c2}"/>
    ${rear
      ? `<rect x="${cx - w + 14}" y="${sh + 26}" width="${2 * w - 28}" height="12" rx="6" fill="#E0121C"/><rect x="${cx - 62}" y="${sh + 58}" width="124" height="34" rx="4" fill="#f2f2f2"/><rect x="${cx - 150}" y="262" width="60" height="10" rx="5" fill="#000"/><rect x="${cx + 90}" y="262" width="60" height="10" rx="5" fill="#000"/>`
      : `<path d="M ${cx - w + 14},${sh + 26} h 96 l -10,20 h -78 z" fill="#fff"/><path d="M ${cx + w - 14},${sh + 26} h -96 l 10,20 h 78 z" fill="#fff"/><rect x="${cx - 98}" y="${sh + 24}" width="196" height="46" rx="8" fill="#0a0a0a"/><path d="M ${cx - 86},${sh + 38} h 172 M ${cx - 86},${sh + 50} h 172 M ${cx - 86},${sh + 60} h 172" stroke="#3a3a3a" stroke-width="3"/><rect x="${cx - 170}" y="246" width="340" height="22" rx="6" fill="#000" opacity=".8"/>`}
  `;
}

function interior(kind) { // local 1000 x 620
  if (kind === 'seats') {
    const seat = (x) => `<g transform="translate(${x} 0)"><rect x="-70" y="60" width="140" height="78" rx="26" fill="#2a2a2a"/><path d="M -120,170 Q -120,140 -80,140 L 80,140 Q 120,140 120,170 L 132,520 L -132,520 Z" fill="url(#seat)"/><path d="M -60,180 V 500 M 0,180 V 500 M 60,180 V 500" stroke="#000" stroke-opacity=".5" stroke-width="3"/><path d="M -110,300 H 110" stroke="#D0111B" stroke-width="3"/></g>`;
    return `<defs><linearGradient id="seat" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3b3b3b"/><stop offset="1" stop-color="#101010"/></linearGradient></defs>
      <rect x="0" y="0" width="1000" height="230" fill="#161616"/><rect x="120" y="30" width="330" height="170" rx="18" fill="#5d5d5d" opacity=".5"/><rect x="550" y="30" width="330" height="170" rx="18" fill="#5d5d5d" opacity=".5"/>
      ${seat(290)}${seat(710)}<rect x="440" y="330" width="120" height="290" rx="14" fill="#1b1b1b"/><rect x="0" y="520" width="1000" height="100" fill="#0a0a0a"/>`;
  }
  return `<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2d2d2d"/><stop offset="1" stop-color="#9a9a9a"/></linearGradient>
      <linearGradient id="dash" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2b2b2b"/><stop offset="1" stop-color="#080808"/></linearGradient></defs>
    <path d="M 60,300 L 190,40 H 810 L 940,300 Z" fill="url(#sky)"/>
    <path d="M 160,300 L 420,205 M 840,300 L 580,205" stroke="#fff" stroke-opacity=".5" stroke-width="3" stroke-dasharray="26 22"/>
    <path d="M 0,0 H 1000 V 620 H 0 Z M 60,300 L 190,40 H 810 L 940,300 Z" fill="#070707" fill-rule="evenodd"/>
    <path d="M 0,300 Q 500,250 1000,300 V 620 H 0 Z" fill="url(#dash)"/>
    <rect x="455" y="318" width="300" height="150" rx="12" fill="#000" stroke="#444" stroke-width="2"/><rect x="471" y="334" width="268" height="118" rx="6" fill="#181818"/><path d="M 490,420 l 50,-40 40,22 50,-50 70,40" stroke="#D0111B" stroke-width="4" fill="none"/>
    <g transform="translate(265 430)"><circle r="128" fill="none" stroke="#1d1d1d" stroke-width="30"/><circle r="128" fill="none" stroke="#555" stroke-width="2"/><path d="M -118,0 H 118 M 0,0 V 120" stroke="#1d1d1d" stroke-width="26"/><circle r="38" fill="#151515" stroke="#555" stroke-width="2"/></g>
    <rect x="800" y="330" width="130" height="34" rx="8" fill="#000" stroke="#444"/><rect x="505" y="500" width="200" height="120" rx="14" fill="#111" stroke="#333"/>`;
}

function wheelDetail(paint) { // local 1000 x 620
  const [c1, c2, c3] = PAINT[paint];
  return `<defs><linearGradient id="wb" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${c1}"/><stop offset=".6" stop-color="${c2}"/><stop offset="1" stop-color="${c3}"/></linearGradient><radialGradient id="wr"><stop offset="0" stop-color="#9a9a9a"/><stop offset=".8" stop-color="#555"/><stop offset="1" stop-color="#222"/></radialGradient></defs>
    <path d="M 0,60 H 1000 V 470 H 800 A 280 280 0 0 0 240,470 H 0 Z" fill="url(#wb)"/>
    <path d="M 0,150 H 1000" stroke="#fff" stroke-opacity=".4" stroke-width="3"/>
    <g transform="translate(520 430)"><circle r="250" fill="#050505"/><circle r="182" fill="url(#wr)"/>${[0, 36, 72, 108, 144].map((d) => `<rect x="-13" y="-178" width="26" height="356" fill="#141414" transform="rotate(${d})"/>`).join('')}<circle r="44" fill="#0c0c0c" stroke="#888" stroke-width="3"/><circle r="182" fill="none" stroke="#000" stroke-width="5"/><path d="M -70,-120 a 140 140 0 0 1 140,0" stroke="#D0111B" stroke-width="16" fill="none"/></g>`;
}

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
const FONT = `font-family="'Arial Narrow','Helvetica Neue Condensed','Roboto Condensed',Arial,Helvetica,sans-serif" font-weight="700"`;

// Studio frame: black backdrop, overhead spot, floor line, ghosted name, slate.
function studio(w, h, { content, name = '', slate = '', floor = 0.74, ghost = true, spotX = 0.5 }) {
  const fy = h * floor;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}">
  <defs>
    <radialGradient id="spot" cx="${spotX}" cy="0.08" r="0.95" gradientUnits="objectBoundingBox"><stop offset="0" stop-color="#6b6b6b"/><stop offset=".35" stop-color="#2a2a2a"/><stop offset=".75" stop-color="#0b0b0b"/><stop offset="1" stop-color="#000"/></radialGradient>
    <radialGradient id="pool" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".6" stop-color="#fff" stop-opacity=".05"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
    <linearGradient id="fl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#161616"/><stop offset="1" stop-color="#000"/></linearGradient>
  </defs>
  <rect width="${w}" height="${h}" fill="#000"/>
  <rect width="${w}" height="${fy}" fill="url(#spot)"/>
  <rect y="${fy}" width="${w}" height="${h - fy}" fill="url(#fl)"/>
  <ellipse cx="${w * spotX}" cy="${fy + (h - fy) * 0.22}" rx="${w * 0.52}" ry="${(h - fy) * 0.5}" fill="url(#pool)"/>
  <rect y="${fy - 1}" width="${w}" height="2" fill="#fff" opacity=".1"/>
  ${ghost && name ? `<text x="${w / 2}" y="${fy - h * 0.2}" text-anchor="middle" ${FONT} font-size="${h * 0.3}" textLength="${w * 0.9}" lengthAdjust="spacingAndGlyphs" fill="none" stroke="#fff" stroke-opacity=".13" stroke-width="2">${esc(name.toUpperCase())}</text>` : ''}
  ${content(w, h, fy)}
  ${slate ? `<g ${FONT} font-size="${Math.max(16, w * 0.0125)}" fill="#fff" fill-opacity=".55"><text x="${w * 0.975}" y="${h - Math.max(18, h * 0.03)}" text-anchor="end" letter-spacing="1">${esc(slate)}</text><rect x="${w * 0.975 + 6}" y="${h - Math.max(18, h * 0.03) - Math.max(11, w * 0.009)}" width="${Math.max(8, w * 0.007)}" height="${Math.max(11, w * 0.009)}" fill="#D0111B" fill-opacity="1"/></g>` : ''}
</svg>`;
}

// place a local-box drawing so its ground line sits on the floor
const place = (inner, { w, lw, lh = 320, scale, cx, fy, ground = 308 }) => {
  const k = (w * scale) / lw; const x = cx - (lw * k) / 2; const y = fy - ground * k + (lh * 0.0);
  return `<g transform="translate(${x.toFixed(1)} ${(y + 6 * k).toFixed(1)}) scale(${k.toFixed(4)})">${inner}</g>`;
};
const reflect = (inner, o) => { // faint floor reflection
  const k = (o.w * o.scale) / o.lw; const x = o.cx - (o.lw * k) / 2; const gy = o.fy + 6 * k;
  return `<g opacity=".16" transform="translate(${x.toFixed(1)} ${(gy + 308 * k * 0.55).toFixed(1)}) scale(${k.toFixed(4)} ${(-k * 0.55).toFixed(4)})">${inner}</g>`;
};

const SHOTS = [
  { key: 'lead', label: 'Front three-quarter (lead)', alt: (c) => `${c.year} ${c.name} in ${c.colour}, front three-quarter view` },
  { key: 'side', label: 'Side profile', alt: (c) => `${c.name} side profile` },
  { key: 'rear34', label: 'Rear three-quarter', alt: (c) => `${c.name} rear three-quarter view` },
  { key: 'front', label: 'Front', alt: (c) => `${c.name} from the front` },
  { key: 'rear', label: 'Rear', alt: (c) => `${c.name} from the rear` },
  { key: 'dash', label: 'Dashboard', alt: (c) => `${c.name} dashboard and steering wheel` },
  { key: 'seats', label: 'Seats', alt: (c) => `${c.name} seats` },
  { key: 'wheel', label: 'Wheel detail', alt: (c) => `${c.name} wheel` }
];

function carShot(c, shot, w, h) {
  const slate = `STAND-IN  ${c.name.toUpperCase()}  ${SHOTS.findIndex((s) => s.key === shot) + 1}/8 ${SHOTS.find((s) => s.key === shot).label.toUpperCase()}`;
  const box = (inner) => `<g transform="scale(${w / 1000} ${h / 620})">${inner}</g>`;
  if (shot === 'dash') return studio(w, h, { slate, ghost: false, content: () => box(interior('dash')) });
  if (shot === 'seats') return studio(w, h, { slate, ghost: false, content: () => box(interior('seats')) });
  if (shot === 'wheel') return studio(w, h, { slate, ghost: false, content: () => box(wheelDetail(c.paint)) });
  if (shot === 'front' || shot === 'rear') {
    return studio(w, h, { slate, name: c.model, content: (W, H, fy) => place(carEnd(c.shape, c.paint, shot === 'rear'), { w: W, lw: 600, scale: 0.52, cx: W / 2, fy }) });
  }
  const flip = shot === 'rear34';
  const scale = shot === 'side' ? 0.8 : 0.9; const cxk = shot === 'lead' ? 0.52 : shot === 'rear34' ? 0.48 : 0.5;
  return studio(w, h, { slate, name: c.model, spotX: cxk, content: (W, H, fy) => {
    const o = { w: W, lw: 1000, scale, cx: W * cxk, fy };
    const inner = carSide(c.shape, c.paint, { flip });
    return reflect(inner, o) + place(inner, o);
  } });
}

// ---- lifestyle scenes -------------------------------------------------------
const skyline = (w, fy, seed = 3) => {
  let x = 0; let out = ''; let i = seed;
  while (x < w) { i = (i * 9301 + 49297) % 233280; const bw = 40 + (i % 90); const bh = 60 + (i % 260); out += `<rect x="${x}" y="${fy - bh}" width="${bw - 4}" height="${bh}" fill="#0d0d0d"/>`;
    for (let yy = fy - bh + 14; yy < fy - 12; yy += 22) for (let xx = x + 8; xx < x + bw - 14; xx += 16) { i = (i * 9301 + 49297) % 233280; if (i % 5 === 0) out += `<rect x="${xx}" y="${yy}" width="6" height="9" fill="#fff" opacity=".35"/>`; }
    x += bw; }
  const tx = w * 0.68; // a tall broadcast tower, generic
  out += `<path d="M ${tx - 5},${fy} L ${tx - 3},${fy - 470} L ${tx + 3},${fy - 470} L ${tx + 5},${fy} Z" fill="#0d0d0d"/><ellipse cx="${tx}" cy="${fy - 330}" rx="22" ry="12" fill="#0d0d0d"/><rect x="${tx - 1}" y="${fy - 560}" width="2" height="92" fill="#0d0d0d"/><circle cx="${tx}" cy="${fy - 560}" r="3" fill="#E0121C"/>`;
  return out;
};
const road = (w, h, fy) => `<path d="M ${w * 0.5 - 40},${fy} L ${w * 0.5 + 40},${fy} L ${w * 0.9},${h} L ${w * 0.1},${h} Z" fill="#0c0c0c"/><path d="M ${w / 2},${fy + 6} L ${w / 2},${h}" stroke="#fff" stroke-opacity=".5" stroke-width="6" stroke-dasharray="40 46"/>`;

const SCENES = {
  hero(w, h, tall) {
    const c = CARS.find((x) => x.slug === 'mercedes-benz-c300');
    return studio(w, h, { floor: tall ? 0.84 : 0.74, spotX: tall ? 0.5 : 0.7, slate: 'STAND-IN  HOME HERO  CAR ON LOCATION, LOW ANGLE', ghost: false, content: (W, H, fy) => {
      const o = { w: W, lw: 1000, scale: tall ? 0.94 : 0.56, cx: W * (tall ? 0.56 : 0.72), fy };
      const inner = carSide(c.shape, c.paint);
      const streaks = [0.2, 0.31, 0.39, 0.5].map((p, i) => `<rect x="${tall ? -W * 0.1 : W * (0.74 - i * 0.03)}" y="${fy * (tall ? p + 0.3 : p + 0.28)}" width="${W * (0.5 + i * 0.12)}" height="${i === 1 ? 5 : 2}" fill="${i === 1 && !tall ? '#D0111B' : '#fff'}" opacity="${i === 1 && !tall ? 0.9 : 0.14}"/>`).join('');
      return skyline(W, fy, 11).replace(/#0d0d0d/g, '#111') + streaks + reflect(inner, o) + place(inner, o);
    } });
  },
  delivery(w, h, tall) {
    const c = CARS.find((x) => x.slug === 'mercedes-benz-glc300');
    return studio(w, h, { floor: tall ? 0.84 : 0.76, spotX: 0.7, slate: 'STAND-IN  DELIVERY  CAR IN A DRIVEWAY, STAFF HANDING OVER KEYS', ghost: false, content: (W, H, fy) => {
      const hx = W * (tall ? 0.3 : 0.6); const hw = W * (tall ? 0.66 : 0.3); const hh = fy * (tall ? 0.24 : 0.56);
      const house = `<path d="M ${hx},${fy} V ${fy - hh} L ${hx + hw / 2},${fy - hh - hw * 0.22} L ${hx + hw},${fy - hh} V ${fy} Z" fill="#141414"/><rect x="${hx + hw * 0.12}" y="${fy - hh * 0.52}" width="${hw * 0.2}" height="${hh * 0.52}" fill="#f4f4f4"/><rect x="${hx + hw * 0.12}" y="${fy - hh * 0.52}" width="${hw * 0.2}" height="${hh * 0.52}" fill="url(#pool)"/><rect x="${hx + hw * 0.5}" y="${fy - hh * 0.62}" width="${hw * 0.34}" height="${hh * 0.3}" fill="#8f8f8f"/><path d="M ${hx + hw * 0.67},${fy - hh * 0.62} v ${hh * 0.3}" stroke="#141414" stroke-width="4"/><path d="M ${hx + hw * 0.08},${fy} L ${hx + hw * 0.36},${fy} L ${hx + hw * 0.6},${H} L ${hx - hw * 0.2},${H} Z" fill="#fff" opacity=".07"/>`;
      const o = { w: W, lw: 1000, scale: tall ? 1.0 : 0.46, cx: W * (tall ? 0.46 : 0.66), fy: fy + (tall ? H * 0.07 : H * 0.05) };
      const inner = carSide(c.shape, c.paint, { flip: true });
      return house + reflect(inner, o) + place(inner, o);
    } });
  },
  owner(w, h, tall) {
    return studio(w, h, { floor: tall ? 0.86 : 0.72, slate: 'STAND-IN  OWNER PROGRAM  LINE-UP OF FLEET CARS', ghost: false, content: (W, H, fy) => {
      const set = [['suvlg', 'white', 0.3, 0.2, 0.86], ['sedan', 'silver', 0.36, 0.5, 0.93], ['fastback', 'black', 0.44, 0.82, 1]];
      return set.map(([s, p, sc, cx, op]) => { const o = { w: W, lw: 1000, scale: sc * (tall ? 1.9 : 1), cx: W * (tall ? cx * 1.5 - 0.2 : cx), fy }; const inner = carSide(s, p); return `<g opacity="${op}">${reflect(inner, o)}${place(inner, o)}</g>`; }).join('');
    } });
  },
  handover(w, h, tall) {
    return studio(w, h, { floor: 0.9, spotX: 0.6, slate: 'STAND-IN  HANDOVER  KEYS PASSING BETWEEN TWO HANDS, CLOSE', ghost: false, content: (W, H) => {
      const k = Math.min(W, H) / 620; const cx = W * 0.58; const cy = H * 0.5;
      return `<g transform="translate(${cx} ${cy}) scale(${k}) rotate(-18)"><rect x="-70" y="-120" width="140" height="240" rx="46" fill="#1b1b1b" stroke="#777" stroke-width="3"/><circle cx="0" cy="-58" r="20" fill="#0a0a0a" stroke="#555" stroke-width="2"/><circle cx="0" cy="4" r="20" fill="#0a0a0a" stroke="#555" stroke-width="2"/><circle cx="0" cy="66" r="20" fill="#D0111B"/><circle cx="0" cy="-150" r="46" fill="none" stroke="#bdbdbd" stroke-width="7"/><rect x="26" y="-196" width="170" height="54" rx="6" fill="#f4f4f4" transform="rotate(24 26 -196)"/></g>`;
    } });
  },
  city(w, h) {
    return studio(w, h, { floor: 0.66, slate: 'STAND-IN  CITY  TORONTO STREET AT DUSK', ghost: false, content: (W, H, fy) => skyline(W, fy, 5) + road(W, H, fy) });
  },
  highway(w, h) {
    const c = CARS.find((x) => x.slug === 'tesla-model-3');
    return studio(w, h, { floor: 0.7, spotX: 0.4, slate: 'STAND-IN  ON THE ROAD  CAR MOVING, ONTARIO HIGHWAY', ghost: false, content: (W, H, fy) => {
      const o = { w: W, lw: 1000, scale: w > h ? 0.5 : 1.1, cx: W * 0.45, fy };
      const inner = carSide(c.shape, c.paint);
      const lines = [0.82, 0.9].map((p) => `<path d="M 0,${H * p} H ${W}" stroke="#fff" stroke-opacity=".4" stroke-width="${H * 0.008}" stroke-dasharray="${W * 0.08} ${W * 0.06}"/>`).join('');
      return `<path d="M 0,${fy} L ${W * 0.2},${fy - H * 0.12} L ${W * 0.45},${fy - H * 0.04} L ${W * 0.7},${fy - H * 0.16} L ${W},${fy - H * 0.05} V ${fy} Z" fill="#0e0e0e"/>` + lines + `<rect x="${o.cx + W * 0.2}" y="${fy - H * 0.06}" width="${W * 0.5}" height="3" fill="#D0111B" opacity=".9"/>` + reflect(inner, o) + place(inner, o);
    } });
  }
};

// ---- write files + manifest -------------------------------------------------
const manifestPath = path.join(ROOT, 'assets/photos.json');
const prev = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath, 'utf8')) : { slots: {}, cars: {} };
const keep = (p, fresh) => (p && p.standIn === false ? p : fresh);
const write = (file, svg) => { fs.writeFileSync(path.join(OUT, file), svg.replace(/\n\s+/g, '\n')); return 'assets/photos/' + file; };

const manifest = {
  _readme: 'One entry per photo slot. To use a real photo: drop the file in assets/photos/, point "src" at it, set width and height to the real pixel size, set "standIn" to false, run `node tools/build.mjs`. See PHOTOS.md for the shot list.',
  slots: {}, cars: {}
};

const SLOT_DEFS = {
  'home.hero':     { scene: 'hero', alt: 'A silver sedan parked on a Toronto street at night', wide: [2400, 1200], tall: [1200, 1500] },
  'home.delivery': { scene: 'delivery', alt: 'A black SUV delivered to a driveway in front of a house', wide: [2400, 1030], tall: [1200, 1500] },
  'home.owner':    { scene: 'owner', alt: 'Three CarmaCars fleet cars lined up side by side', wide: [2400, 1030], tall: [1200, 1200] },
  'how.handover':  { scene: 'handover', alt: 'A car key being handed over', wide: [1800, 1200], tall: [1200, 1200] },
  'delivery.hero': { scene: 'delivery', alt: 'A car arriving at a home for delivery', wide: [2400, 1030], tall: [1200, 1200] },
  'owners.hero':   { scene: 'owner', alt: 'Cars in the CarmaCars fleet', wide: [2400, 1030], tall: [1200, 1200] },
  'contact.city':  { scene: 'city', alt: 'A Toronto street at dusk', wide: [2400, 1030], tall: [1200, 1200] },
  'fleet.band':    { scene: 'highway', alt: 'A white sedan on an Ontario highway', wide: [2400, 800], tall: [1200, 900] },
  'requirements.band': { scene: 'handover', alt: 'A key fob on a dark surface', wide: [2400, 1030], tall: [1200, 1200] }
};
let n = 0;
for (const [slot, d] of Object.entries(SLOT_DEFS)) {
  const base = slot.replace('.', '-');
  const wide = write(`${base}-wide.svg`, SCENES[d.scene](d.wide[0], d.wide[1], false));
  const tall = write(`${base}-tall.svg`, SCENES[d.scene](d.tall[0], d.tall[1], true)); n += 2;
  manifest.slots[slot] = keep(prev.slots?.[slot], { alt: d.alt, standIn: true, wide: { src: wide, width: d.wide[0], height: d.wide[1] }, tall: { src: tall, width: d.tall[0], height: d.tall[1] } });
}
for (const c of CARS) {
  const gallery = SHOTS.map((s) => {
    const src = write(`${c.slug}-${s.key}.svg`, carShot(c, s.key, 1800, 1200)); n++;
    const fresh = { shot: s.key, label: s.label, alt: s.alt(c), standIn: true, src, width: 1800, height: 1200 };
    const old = prev.cars?.[c.slug]?.gallery?.find((g) => g.shot === s.key);
    return keep(old, fresh);
  });
  manifest.cars[c.slug] = { gallery };
}
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
console.log(`stand-ins written: ${n} SVG files; manifest: assets/photos.json`);
