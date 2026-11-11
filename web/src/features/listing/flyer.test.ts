import { test } from 'node:test';
import assert from 'node:assert/strict';
import { drawFlyer, fitCap, flyerLayout, flyerText, hex, textWidth } from './flyer.ts';

const grey = (W: number, H: number) => ({ width: W, height: H, data: new Uint8ClampedArray(W * H * 4).fill(160) });
const px = (img: { width: number; data: Uint8ClampedArray }, x: number, y: number): [number, number, number] => { const i = (y * img.width + x) * 4; return [img.data[i]!, img.data[i + 1]!, img.data[i + 2]!]; };

test('the words: capitals and the signs the letters have, accents folded, anything else a space', () => {
  assert.equal(flyerText('From $89 a day!'), 'FROM $89 A DAY!');
  assert.equal(flyerText('Montréal — 2023 C 300'), 'MONTREAL 2023 C 300');
  assert.equal(flyerText(null), '');
  assert.deepEqual(hex('#E10600', [0, 0, 0]), [225, 6, 0]);
  assert.deepEqual(hex('red', [1, 2, 3]), [1, 2, 3]);
});

test('a long line is made smaller to fit, never wider than its room', () => {
  const t = 'A VERY LONG HEADLINE THAT WOULD NOT FIT ON ONE BAND AT ALL';
  const cap = fitCap(t, 62, 900);
  assert.ok(cap < 62 && textWidth(t, cap) <= 900);
  assert.equal(fitCap('SHORT', 62, 900), 62);
});

test('the flyer: the band darkens the bottom, the offer is in the accent colour, the top stays the photo (but the logo and badge)', () => {
  const src = grey(900, 600);
  const out = drawFlyer(src, { headline: '2023 Mercedes-Benz C 300', offer: 'From $89 a day', cta: 'Book at carmacars.ca', badge: 'No credit card', logo: true, band: '#000000', accent: '#FF0000', text: '#FFFFFF' });
  const k = flyerLayout(900, 600);
  assert.ok(px(out, 450, 590)[0]! < 60, 'the band is dark');
  assert.deepEqual(px(out, 450, 200), [160, 160, 160], 'the middle of the photo is untouched');
  let red = 0, white = 0;
  for (let y = k.band.y; y < 600; y++) for (let x = 0; x < 900; x++) { const [r, g, b] = px(out, x, y); if (r > 200 && g < 60 && b < 60) red++; if (r > 220 && g > 220 && b > 220) white++; }
  assert.ok(red > 500, `the offer and the call to action in the accent colour (${red})`);
  assert.ok(white > 300, `the headline in the text colour (${white})`);
  assert.deepEqual(px(src, 450, 590), [160, 160, 160], 'the photo given is not changed');
});

test('no words, no logo: only the band', () => {
  const out = drawFlyer(grey(600, 400), { logo: false });
  assert.deepEqual(px(out, 30, 20), [160, 160, 160]);
});
