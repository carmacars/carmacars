// The studio images of the sample cars (prototype/tools/make-standins.mjs, the files in web/public/sample-photos/cars/),
// as a module of the site, so a real car with no photo yet gets stand-ins drawn by the very same system: the black
// studio, the overhead spot, the floor line, the model's name in large outlined letters behind the car, the same
// eight shots at 1800 x 1200. Served by app/sample-photos/studio/[...p]/route.ts (migration 0073 points
// app.vehicle_sample_photos at it). Pure string building (the logo's shapes are read from the showroom's preset).
// r35 S2: the frame is the showroom v2 (studio() below); the car sits on its floor line (80% of the height).
import logoData from '../listing/presets/showroom-logo.json' with { type: 'json' };
import { plateSvgInner } from '../listing/plate-art.ts';
/** r35 S2: the rear plate of every car drawn here is the company's CARMA Ontario plate (no front plate). */
const CARMA_PLATE = plateSvgInner();

export const PAINT: Record<string, [string, string, string]> = {
  white: ['#F4F4F4', '#B9B9B9', '#6E6E6E'],
  silver: ['#D2D2D2', '#8C8C8C', '#4A4A4A'],
  grey: ['#8E8E8E', '#555555', '#262626'],
  black: ['#4A4A4A', '#1C1C1C', '#070707'],
  red: ['#EE3A42', '#C20F18', '#5C060A'],
  // the colours a real car can have beyond the five of the sample set, drawn the same way
  blue: ['#5E86C9', '#24477F', '#0B1C3A'],
  green: ['#6E9B78', '#2F5E3B', '#0F2615'],
  beige: ['#E2D3B5', '#A8916A', '#5A4A30'],
  brown: ['#8F6A4E', '#553923', '#22160C'],
  orange: ['#F28C3A', '#C2560F', '#5C2606'],
  yellow: ['#F5D547', '#C9A50F', '#5E4C06'],
  // the vehicle pages' twelfth colour (0097)
  gold: ['#E3C477', '#B8902F', '#5A4412']
};

type Shape = { x0: number; x1: number; hh: number; xc: number; hc: number; xr1: number; hr: number; xr2: number; xg: number; hd: number; wf: number; wr: number; r: number; base: number };
export const SHAPES: Record<string, Shape> = {
  compact:  { x0: 70,  x1: 930, hh: 178, xc: 335, hc: 160, xr1: 452, hr: 97,  xr2: 630, xg: 792, hd: 148, wf: 222, wr: 762, r: 45, base: 262 },
  sedan:    { x0: 45,  x1: 955, hh: 180, xc: 335, hc: 161, xr1: 455, hr: 99,  xr2: 645, xg: 808, hd: 152, wf: 212, wr: 778, r: 46, base: 262 },
  fastback: { x0: 60,  x1: 940, hh: 178, xc: 345, hc: 160, xr1: 470, hr: 101, xr2: 600, xg: 838, hd: 150, wf: 218, wr: 770, r: 46, base: 262 },
  suv:      { x0: 70,  x1: 930, hh: 158, xc: 318, hc: 136, xr1: 420, hr: 62,  xr2: 735, xg: 872, hd: 124, wf: 222, wr: 762, r: 53, base: 252 },
  suvlg:    { x0: 45,  x1: 955, hh: 150, xc: 318, hc: 128, xr1: 425, hr: 50,  xr2: 760, xg: 898, hd: 116, wf: 215, wr: 780, r: 58, base: 250 },
  van:      { x0: 45,  x1: 955, hh: 166, xc: 255, hc: 142, xr1: 380, hr: 46,  xr2: 820, xg: 925, hd: 104, wf: 200, wr: 790, r: 48, base: 258 },
  roadster: { x0: 110, x1: 890, hh: 190, xc: 405, hc: 177, xr1: 478, hr: 128, xr2: 585, xg: 676, hd: 174, wf: 255, wr: 742, r: 44, base: 264 }
};

let uid = 0;
type K = keyof Shape;
// Side profile, nose to the left. Local box 1000 x 320, ground line at y=308.
function carSide(shape: string, paint: string, { flip = false } = {}) {
  const s0 = SHAPES[shape]!; const s = { ...s0 }; const [c1, c2, c3] = PAINT[paint]!; const id = 'c' + (uid++);
  for (const k of ['x0', 'x1', 'xc', 'xr1', 'xr2', 'xg', 'wf', 'wr'] as K[]) s[k] = 500 + (s0[k] - 500) * 0.8; // real-car proportions
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
  const wheel = (x: number) => `<g transform="translate(${x} ${wy})"><circle r="${s.r}" fill="#050505"/><circle r="${s.r * 0.72}" fill="url(#${id}rim)"/><circle r="${s.r * 0.72}" fill="none" stroke="#000" stroke-width="2"/>${[0, 36, 72, 108, 144].map((d) => `<rect x="-3" y="${-s.r * 0.7}" width="6" height="${s.r * 1.4}" fill="#1b1b1b" transform="rotate(${d})"/>`).join('')}<circle r="${s.r * 0.17}" fill="#101010" stroke="#777" stroke-width="1.5"/></g>`;
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
function carEnd(shape: string, paint: string, rear: boolean) {
  const [c1, c2, c3] = PAINT[paint]!; const id = 'e' + (uid++);
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
      ? `<rect x="${cx - w + 14}" y="${sh + 26}" width="${2 * w - 28}" height="12" rx="6" fill="#E0121C"/><g transform="translate(${cx - 54} ${sh + 48}) scale(0.18)">${CARMA_PLATE}</g><rect x="${cx - 150}" y="262" width="60" height="10" rx="5" fill="#000"/><rect x="${cx + 90}" y="262" width="60" height="10" rx="5" fill="#000"/>`
      : `<path d="M ${cx - w + 14},${sh + 26} h 96 l -10,20 h -78 z" fill="#fff"/><path d="M ${cx + w - 14},${sh + 26} h -96 l 10,20 h 78 z" fill="#fff"/><rect x="${cx - 98}" y="${sh + 24}" width="196" height="46" rx="8" fill="#0a0a0a"/><path d="M ${cx - 86},${sh + 38} h 172 M ${cx - 86},${sh + 50} h 172 M ${cx - 86},${sh + 60} h 172" stroke="#3a3a3a" stroke-width="3"/><rect x="${cx - 170}" y="246" width="340" height="22" rx="6" fill="#000" opacity=".8"/>`}
  `;
}

function interior(kind: string) { // local 1000 x 620
  if (kind === 'seats') {
    const seat = (x: number) => `<g transform="translate(${x} 0)"><rect x="-70" y="60" width="140" height="78" rx="26" fill="#2a2a2a"/><path d="M -120,170 Q -120,140 -80,140 L 80,140 Q 120,140 120,170 L 132,520 L -132,520 Z" fill="url(#seat)"/><path d="M -60,180 V 500 M 0,180 V 500 M 60,180 V 500" stroke="#000" stroke-opacity=".5" stroke-width="3"/><path d="M -110,300 H 110" stroke="#D0111B" stroke-width="3"/></g>`;
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

function wheelDetail(paint: string) { // local 1000 x 620
  const [c1, c2, c3] = PAINT[paint]!;
  return `<defs><linearGradient id="wb" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${c1}"/><stop offset=".6" stop-color="${c2}"/><stop offset="1" stop-color="${c3}"/></linearGradient><radialGradient id="wr"><stop offset="0" stop-color="#9a9a9a"/><stop offset=".8" stop-color="#555"/><stop offset="1" stop-color="#222"/></radialGradient></defs>
    <path d="M 0,60 H 1000 V 470 H 800 A 280 280 0 0 0 240,470 H 0 Z" fill="url(#wb)"/>
    <path d="M 0,150 H 1000" stroke="#fff" stroke-opacity=".4" stroke-width="3"/>
    <g transform="translate(520 430)"><circle r="250" fill="#050505"/><circle r="182" fill="url(#wr)"/>${[0, 36, 72, 108, 144].map((d) => `<rect x="-13" y="-178" width="26" height="356" fill="#141414" transform="rotate(${d})"/>`).join('')}<circle r="44" fill="#0c0c0c" stroke="#888" stroke-width="3"/><circle r="182" fill="none" stroke="#000" stroke-width="5"/><path d="M -70,-120 a 140 140 0 0 1 140,0" stroke="#D0111B" stroke-width="16" fill="none"/></g>`;
}

const esc = (s: string) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
const FONT = `font-family="'Inter Display','Inter','Helvetica Neue',Helvetica,Arial,sans-serif" font-weight="800"`;

// r35 S2 (1054): the frame is the showroom v2 of the listing photos (features/listing/showroom.ts), drawn as SVG: a dark
// dealership in one-point perspective, ceiling light strips, a slatted walnut wall between two light strips, the CarmaCars
// logo as the wall's big lit sign, the model's name in metal letters under it, a polished floor that mirrors the wall, a
// vignette. The coordinates are those of the 1800 x 1200 room, scaled to the frame.
const LOGO_D = (logoData as { viewBox: number[]; paths: Array<{ fill: number[]; polys: number[][] }> }).paths.map((p) => ({
  fill: `rgb(${p.fill.join(',')})`,
  d: p.polys.map((poly) => { const pts: string[] = []; for (let i = 0; i + 1 < poly.length; i += 2) pts.push(`${poly[i]!.toFixed(1)},${poly[i + 1]!.toFixed(1)}`); return `M${pts.join('L')}Z`; }).join('')
}));
const LOGO_VB = (logoData as { viewBox: number[] }).viewBox as [number, number, number, number];
type StudioOpts = { content: (w: number, h: number, fy: number) => string; name?: string; slate?: string; floor?: number; ghost?: boolean; spotX?: number; slateTop?: boolean };
export function studio(w: number, h: number, { content, name = '', slate = '', floor = 0.8, ghost = true, slateTop = false }: StudioOpts) {
  const fy = h * floor; const sy = slateTop ? Math.max(30, h * 0.04) : h - Math.max(18, h * 0.03); const sf = Math.max(16, w * (slateTop ? 0.0085 : 0.0125));
  const k = Math.min(w / 1800, h / 1200), ox = (w - 1800 * k) / 2, oy = (h - 1200 * k) / 2;
  const lw = 900, lk = lw / LOGO_VB[2], lx = (1800 - lw) / 2, ly = 146;
  const logo = LOGO_D.map((p) => `<path d="${p.d}" fill="${p.fill}"/>`).join('');
  const nm = ghost && name ? esc(name.toUpperCase()) : '';
  const slats: string[] = [];
  for (let x = 380; x < 1420; x += 18) slats.push(`<rect x="${x + 3}" y="123" width="15" height="567" fill="${['#3b2c21', '#36281e', '#3f2f23', '#33261c'][((x - 380) / 18) % 4]}"/>`);
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}">
  <defs>
    <linearGradient id="srw" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#55555a"/><stop offset=".12" stop-color="#2e2e31"/><stop offset=".5" stop-color="#202023"/><stop offset="1" stop-color="#161618"/></linearGradient>
    <linearGradient id="srs" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".25" stop-color="#fff" stop-opacity=".04"/><stop offset="1" stop-color="#000" stop-opacity=".35"/></linearGradient>
    <linearGradient id="srsw" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#0d0d0f"/><stop offset="1" stop-color="#1d1d20"/></linearGradient>
    <linearGradient id="srsw2" x1="1" y1="0" x2="0" y2="0"><stop offset="0" stop-color="#0d0d0f"/><stop offset="1" stop-color="#1d1d20"/></linearGradient>
    <linearGradient id="srf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1a1a1d"/><stop offset=".25" stop-color="#0f0f11"/><stop offset="1" stop-color="#060607"/></linearGradient>
    <linearGradient id="srm" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9a9ca2"/><stop offset="1" stop-color="#4b4d52"/></linearGradient>
    <radialGradient id="srp" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#fff" stop-opacity=".1"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
    <radialGradient id="srv" cx=".5" cy=".52" r=".75"><stop offset=".55" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".55"/></radialGradient>
    <filter id="srg" x="-20%" y="-60%" width="140%" height="220%"><feGaussianBlur stdDeviation="22"/></filter>
    <filter id="srl" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="6"/></filter>
    <filter id="srb" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="9"/></filter>
    <clipPath id="srfc"><path d="M0,743 L210,700 L1590,700 L1800,743 L1800,1200 L0,1200 Z"/></clipPath>
  </defs>
  <rect width="${w}" height="${h}" fill="#08080a"/>
  <g transform="translate(${ox.toFixed(1)} ${oy.toFixed(1)}) scale(${k.toFixed(5)})">
  <g id="srwall">
    <rect width="1800" height="120" fill="#0a0a0c"/>
    <g stroke="#f4f0e8" stroke-width="5" filter="url(#srl)" opacity=".9"><path d="M140,14 H1660 M200,64 H1600 M467,0 L560,120 M1333,0 L1240,120"/></g>
    <g stroke="#fbf8f2" stroke-width="3"><path d="M140,14 H1660 M200,64 H1600 M467,0 L560,120 M1333,0 L1240,120"/></g>
    <path d="M0,-14 L210,120 L210,700 L0,743 Z" fill="url(#srsw)"/>
    <path d="M1800,-14 L1590,120 L1590,700 L1800,743 Z" fill="url(#srsw2)"/>
    <rect x="210" y="120" width="1380" height="580" fill="url(#srw)"/>
    <ellipse cx="900" cy="470" rx="620" ry="260" fill="url(#srp)"/>
    <rect x="380" y="123" width="1040" height="567" fill="#120d0a"/>
    ${slats.join('')}
    <rect x="380" y="123" width="1040" height="567" fill="url(#srs)"/>
    <rect x="210" y="120" width="1380" height="4" fill="#e9e6df"/>
    <g fill="#fff4e4"><rect x="369" y="138" width="4" height="544"/><rect x="1426" y="138" width="4" height="544"/></g>
    <g fill="#fff4e4" opacity=".55" filter="url(#srl)"><rect x="365" y="138" width="12" height="544"/><rect x="1422" y="138" width="12" height="544"/></g>
    <rect x="210" y="690" width="1380" height="10" fill="#0a0a0b"/>
    <g transform="translate(${lx} ${ly}) scale(${lk.toFixed(5)}) translate(${-LOGO_VB[0]} ${-LOGO_VB[1]})">
      <g filter="url(#srg)" opacity=".75" fill="#fff6ea">${LOGO_D.map((p) => `<path d="${p.d}"/>`).join('')}</g>${logo}
    </g>
    ${nm ? studioLettering(name.toUpperCase()).lines.map((l) => `<text x="900" y="${l.y}" text-anchor="middle" ${FONT} font-size="${l.size}" textLength="${l.length}" lengthAdjust="spacingAndGlyphs" fill="url(#srm)" opacity=".92">${esc(l.text)}</text>`).join('') : ''}
  </g>
  <rect y="700" width="1800" height="500" fill="url(#srf)" clip-path="url(#srfc)"/>
  <g clip-path="url(#srfc)" opacity=".22" filter="url(#srb)"><use href="#srwall" transform="translate(0 1400) scale(1 -1)"/></g>
  </g>
  ${content(w, h, fy)}
  <rect width="${w}" height="${h}" fill="url(#srv)"/>
  ${slate ? `<g ${FONT} font-size="${sf}" fill="#fff" fill-opacity=".55"><text x="${w * 0.975}" y="${sy}" text-anchor="end" letter-spacing="1">${esc(slate)}</text><rect x="${w * 0.975 + 6}" y="${sy - Math.max(11, w * 0.009)}" width="${Math.max(8, w * 0.007)}" height="${Math.max(11, w * 0.009)}" fill="#D0111B" fill-opacity="1"/></g>` : ''}
</svg>`;
}

// place a local-box drawing so its ground line sits on the floor
type Place = { w: number; lw: number; lh?: number; scale: number; cx: number; fy: number; ground?: number };
const place = (inner: string, { w, lw, lh = 320, scale, cx, fy, ground = 308 }: Place) => {
  const k = (w * scale) / lw; const x = cx - (lw * k) / 2; const y = fy - ground * k + (lh * 0.0);
  return `<g transform="translate(${x.toFixed(1)} ${(y + 6 * k).toFixed(1)}) scale(${k.toFixed(4)})">${inner}</g>`;
};
const reflect = (inner: string, o: Place) => { // faint floor reflection
  const k = (o.w * o.scale) / o.lw; const x = o.cx - (o.lw * k) / 2; const gy = o.fy + 6 * k;
  return `<g opacity=".16" transform="translate(${x.toFixed(1)} ${(gy + 308 * k * 0.55).toFixed(1)}) scale(${k.toFixed(4)} ${(-k * 0.55).toFixed(4)})">${inner}</g>`;
};

type Car = { year: number | string; name: string; model: string; colour: string; shape: string; paint: string };
export const SHOTS: Array<{ key: string; label: string; alt: (c: Car) => string }> = [
  { key: 'lead', label: 'Front three-quarter (lead)', alt: (c) => `${c.year} ${c.name} in ${c.colour}, front three-quarter view` },
  { key: 'side', label: 'Side profile', alt: (c) => `${c.name} side profile` },
  { key: 'rear34', label: 'Rear three-quarter', alt: (c) => `${c.name} rear three-quarter view` },
  { key: 'front', label: 'Front', alt: (c) => `${c.name} from the front` },
  { key: 'rear', label: 'Rear', alt: (c) => `${c.name} from the rear` },
  { key: 'dash', label: 'Dashboard', alt: (c) => `${c.name} dashboard and steering wheel` },
  { key: 'seats', label: 'Seats', alt: (c) => `${c.name} seats` },
  { key: 'wheel', label: 'Wheel detail', alt: (c) => `${c.name} wheel` }
];

export function carShot(c: Car, shot: string, w: number, h: number, slateText?: string) {
  uid = 0;
  // r35 S2: the sample cars are showcase listings and look like real ones (no slate); a real car's stand-in says so
  const slate = slateText ?? '';
  const box = (inner: string) => `<g transform="scale(${w / 1000} ${h / 620})">${inner}</g>`;
  if (shot === 'dash') return studio(w, h, { slate, ghost: false, content: () => box(interior('dash')) });
  if (shot === 'seats') return studio(w, h, { slate, ghost: false, content: () => box(interior('seats')) });
  if (shot === 'wheel') return studio(w, h, { slate, ghost: false, content: () => box(wheelDetail(c.paint)) });
  if (shot === 'front' || shot === 'rear') {
    return studio(w, h, { slate, content: (W: number, H: number, fy: number) => place(carEnd(c.shape, c.paint, shot === 'rear'), { w: W, lw: 600, scale: 0.52, cx: W / 2, fy }) });
  }
  const flip = shot === 'rear34';
  const scale = shot === 'side' ? 0.8 : 0.9; const cxk = shot === 'lead' ? 0.52 : shot === 'rear34' ? 0.48 : 0.5;
  return studio(w, h, { slate, ...(shot === 'lead' ? { name: c.model } : {}), spotX: cxk, content: (W: number, H: number, fy: number) => {
    const o = { w: W, lw: 1000, scale, cx: W * cxk, fy };
    const inner = carSide(c.shape, c.paint, { flip });
    return reflect(inner, o) + place(inner, o);
  } });
}


/** Body shape of the drawing for a car: from the body type key of app.sample_body_key and the body text. */
export function studioShape(body: string | null | undefined, seats?: number | null): string {
  const b = (body ?? '').toLowerCase();
  if (/convertible|cabriolet|roadster|spyder|spider/.test(b)) return 'roadster';
  if (/coupe/.test(b)) return 'fastback';
  if (/van|minivan|mpv/.test(b)) return 'van';
  if (/pick.?up|truck/.test(b)) return 'suvlg';
  if (/suv|sport utility|crossover|cuv/.test(b)) return (seats ?? 5) >= 7 || /full|large|mid.?size/.test(b) ? 'suvlg' : 'suv';
  if (/hatch|liftback|wagon|compact/.test(b)) return 'compact';
  return 'sedan';
}
/** Paint of the drawing for a car's colour name. */
export function studioPaint(colour: string | null | undefined): string {
  const c = (colour ?? '').toLowerCase();
  const m: Array<[RegExp, string]> = [[/white|pearl|snow|ivory|alabaster|glacier|polar|chalk/, 'white'], [/black|obsidian|onyx|ebony|jet|midnight|night/, 'black'],
    [/silver|platinum|aluminium|aluminum|chrome|steel/, 'silver'], [/grey|gray|graphite|gunmetal|charcoal|slate|titanium|magnetic|cement|ash/, 'grey'],
    [/red|maroon|burgundy|crimson|ruby|cherry|wine/, 'red'], [/blue|navy|azure|cobalt|sapphire|teal/, 'blue'], [/green|olive|emerald|lime|jade/, 'green'],
    [/gold/, 'gold'], [/beige|tan|sand|champagne|cream|khaki/, 'beige'], [/brown|bronze|copper|mocha|espresso/, 'brown'], [/orange|amber/, 'orange'], [/yellow/, 'yellow']];
  return m.find(([re]) => re.test(c))?.[1] ?? 'grey';
}
/** r38: the model's name on the wall panel (x 380 to 1420), never wider than LETTER_MAX: one line at up to 150 units, smaller
 *  when long, else two lines split at the space nearest the middle (the owner, Nov 11: "writing in the photos that doesn't fit").
 *  A letter of the font is about 0.7 of its size wide; textLength holds each line to its width. */
export const LETTER_MAX = 960;
const LETTER_W = 0.7;
export function studioLettering(name: string): { lines: Array<{ text: string; size: number; length: number; y: number }> } {
  const t = name.replace(/\s+/g, ' ').trim();
  if (!t) return { lines: [] };
  const fit = (n: number, cap: number) => Math.max(56, Math.min(cap, Math.floor(LETTER_MAX / (Math.max(1, n) * LETTER_W))));
  const len = (text: string, size: number) => Math.min(LETTER_MAX, Math.round(text.length * size * LETTER_W));
  const one = fit(t.length, 150);
  const sp = [...t].map((c, i) => (c === ' ' ? i : -1)).filter((i) => i > 0);
  if (one >= 110 || !sp.length) return { lines: [{ text: t, size: one, length: len(t, one), y: 450 }] };
  const cut = sp.reduce((a, b) => (Math.abs(b - t.length / 2) < Math.abs(a - t.length / 2) ? b : a));
  const [a, b] = [t.slice(0, cut).trim(), t.slice(cut + 1).trim()];
  const size = fit(Math.max(a.length, b.length), 120);
  const top = 300 + size; // below the logo, as the one line of 150 (its top at 300)
  return { lines: [{ text: a, size, length: len(a, size), y: top }, { text: b, size, length: len(b, size), y: top + Math.round(size * 1.08) }] };
}

/** The shot keys, in gallery order, with the listing shot type each stands for (as the sample cars use them). */
export const STUDIO_SHOT_TYPE: Record<string, string> = { lead: 'front_left', side: 'left', rear34: 'rear_left', front: 'front', rear: 'rear', dash: 'dashboard', seats: 'front_seats', wheel: 'wheel' };
/** The lettering behind the car: the model's name, as the sample cars show it (letters, digits, spaces and - & . / only). */
export const studioName = (s: string) => s.toUpperCase().replace(/[^A-Z0-9 &./-]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 24);
/** The longest name lettered behind a car (characters), so it stays big enough to read and fits the wall. */
export const LETTER_NAME_MAX = 18;
const MAKES = /^(?:MERCEDES(?:[- ]BENZ)?|LAND ROVER|VOLKSWAGEN|CHEVROLET|ROLLS[- ]ROYCE|ASTON MARTIN|ALFA ROMEO|MINI|BMW|AUDI|PORSCHE|TOYOTA|HONDA|FORD|NISSAN|HYUNDAI|KIA|MAZDA|SUBARU|LEXUS|ACURA|INFINITI|CADILLAC|GMC|JEEP|DODGE|RAM|TESLA|VOLVO|JAGUAR|BENTLEY|LAMBORGHINI|FERRARI|MASERATI|GENESIS|LINCOLN|BUICK|CHRYSLER|VW|CHEVY)(?=[ -]|$)[ -]*/;
/** Words that say the body, drive or trim, not the model: left out of the lettering. */
const DROP = new Set(['COUPE', 'SEDAN', '4-DOOR', '2-DOOR', '4DOOR', '2DOOR', 'GRAN', 'SPORTBACK', 'CABRIOLET', 'CONVERTIBLE', 'ROADSTER', 'HATCHBACK', 'WAGON',
  'ESTATE', 'SUV', 'SAV', 'SAC', 'AVANT', 'LIFTBACK', 'CREW', 'CAB', '4MATIC', '4MATIC+', 'XDRIVE', 'AWD', '4WD', 'FWD', 'RWD', 'COMFORTLINE', 'HIGHLINE', 'TRENDLINE',
  'EXECLINE', 'LIMITED', 'PREMIUM', 'LUXURY', 'TECHNIK', 'STINGRAY', 'BASE', 'EDITION']);
/** r33 (0700), r40: the short word lettered behind the cover photo from the car's model. Owner, Nov 12: the name was too long.
 *  The year, the maker, body styles, drive and trims go ("2024 Volkswagen Jetta Comfortline Sport": JETTA; "Mercedes-Benz GLC
 *  GLC43 AMG Coupe": GLC43 AMG); a class word the model code repeats goes ("S-Class Maybach S580": MAYBACH S580, "AMG GT GT53
 *  4-Door Coupe": AMG GT 53, "BMW 4 Series M440i Gran Coupe": M440I); an engine (V8) goes; at most LETTER_NAME_MAX characters.
 *  A Mercedes class of one letter keeps the word when no code follows ("C-Class": C CLASS); a longer one is its letters alone
 *  ("CLA-Class": CLA); anything else as is (AMG GT, CTS, F-150, CR-V). Idempotent. */
export function letteringName(model: string): string {
  let s = (model ?? '').toUpperCase().replace(/[^A-Z0-9 &./+-]+/g, ' ').replace(/\s+/g, ' ').trim();
  s = s.replace(/^(?:19|20)\d\d\s+/, '');
  const noMake = s.replace(MAKES, '').trim();
  if (noMake) s = noMake;
  s = s.replace(/\b([A-Z]{1,4})[ -]?CLASS\b/g, (_m, c: string) => (c.length === 1 ? `${c} CLASS` : c));
  const toks = s.split(' ').filter(Boolean);
  const hasCode = (from: number) => toks.slice(from).some((x) => /\d/.test(x) && x.length >= 2 && !DROP.has(x) && !/^V\d{1,2}$/.test(x));
  const out: string[] = [];
  toks.forEach((t, i) => {
    if (DROP.has(t) || /^V\d{1,2}$/.test(t) || /^\d\.\d$/.test(t)) return;
    // "SPORT" after a trim word (Jetta Comfortline Sport) is a trim; "Range Rover Sport" keeps it
    if (t === 'SPORT' && i > 0 && DROP.has(toks[i - 1]!)) return;
    // "S CLASS ... S580", "4 SERIES M440I": the model code says it
    if ((t === 'CLASS' || t === 'SERIES') && out.length && hasCode(i + 1)) { out.pop(); return; }
    out.push(t);
  });
  // a family word the model code repeats (GLC GLC43, GLS ... GLS600): the code says it
  const kept = out.filter((t, i) => !(/^[A-Z]+$/.test(t) && t !== 'AMG' && out.slice(i + 1).some((x) => x.length > t.length && x.startsWith(t) && /^\d/.test(x.slice(t.length)))));
  // AMG GT53 -> AMG GT 53 (the maker writes GT 53)
  let words = kept.flatMap((t, i) => { const m = /^GT(\d{2,3})$/.exec(t); return m && kept[i - 1] === 'AMG' ? ['GT', m[1]!] : [t]; });
  if (!words.length) words = toks.length ? [toks[0]!] : [];
  while (words.length > 1 && words.join(' ').length > LETTER_NAME_MAX) words = words.slice(0, -1); // trailing words go first
  return words.join(' ').slice(0, LETTER_NAME_MAX).trim();
}
/** One stand-in image of a real car without photos: same drawing as the samples, a quiet "Representative photo" slate. */
export function standInSvg(o: { shape: string; paint: string; shot: string; name: string }): string | null {
  if (!SHAPES[o.shape] || !PAINT[o.paint] || !SHOTS.some((s) => s.key === o.shot)) return null;
  const name = letteringName(o.name);
  return carShot({ year: '', name, model: name, colour: o.paint, shape: o.shape, paint: o.paint }, o.shot, 1800, 1200, 'REPRESENTATIVE PHOTO').replace(/\n\s+/g, '\n');
}
