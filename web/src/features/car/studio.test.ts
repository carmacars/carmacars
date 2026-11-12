import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { carShot, LETTER_MAX, standInSvg, studioLettering, studioName, studioPaint, studioShape } from './studio.ts';

// The 2023 Toyota Camry of the sample set (prototype/tools/src/data.mjs): shape sedan, paint black.
const camry = { year: 2023, name: 'Toyota Camry', model: 'Camry', colour: 'Midnight Black', shape: 'sedan', paint: 'black' };

test('the module draws the sample cars byte for byte (same studio system as the samples)', () => {
  for (const shot of ['lead', 'side', 'rear34', 'front', 'rear', 'dash', 'seats', 'wheel']) {
    const file = readFileSync(new URL(`../../../public/sample-photos/cars/toyota-camry-${shot}.svg`, import.meta.url), 'utf8');
    // gradient ids are numbered per run of the generator (c85b there, c0b here): compare with the numbers taken out
    const ids = (x: string) => x.replace(/\b([ce])\d+(b|g|s|rim)\b/g, '$1#$2');
    assert.equal(ids(carShot(camry, shot, 1800, 1200).replace(/\n\s+/g, '\n')), ids(file), shot);
  }
});

test('a real car stand-in: the model name lettered behind the car, a quiet representative slate, no STAND-IN', () => {
  const svg = standInSvg({ shape: 'sedan', paint: 'black', shot: 'lead', name: 'Malibu' })!;
  assert.match(svg, /viewBox="0 0 1800 1200"/);
  assert.match(svg, />MALIBU<\/text>/);
  assert.match(svg, /fill="url\(#srm\)"/, 'metal letters on the showroom wall');
  assert.match(svg, /REPRESENTATIVE PHOTO/);
  assert.doesNotMatch(svg, /STAND-IN/);
  // r35 S2: the showroom v2: the big lit logo sign, the slatted wall, the light strips; the sample cars carry no slate
  assert.match(svg, /filter="url\(#srg\)"/);
  assert.match(svg, /<clipPath id="srfc">/);
  assert.doesNotMatch(carShot(camry, 'lead', 1800, 1200), /STAND-IN|font-size="\d+(\.\d+)?" fill="#fff" fill-opacity="\.55"/);
  // the same backdrop as the sample: identical up to the lettering and the slate
  const sample = carShot(camry, 'lead', 1800, 1200).replace(/\n\s+/g, '\n');
  const strip = (s: string) => s.replace(/\b([ce])\d+(b|g|s|rim)\b/g, '$1#$2').replace(/>[A-Z0-9 &./-]+<\/text>/g, '><\/text>').replace(/<g font-family[^]*?<\/g>\n?/, '').replace(/textLength="[\d.]+"/g, '');
  assert.equal(strip(svg), strip(sample));
});

test('unknown shapes, paints or shots are refused', () => {
  assert.equal(standInSvg({ shape: 'boat', paint: 'black', shot: 'lead', name: 'X' }), null);
  assert.equal(standInSvg({ shape: 'sedan', paint: 'plaid', shot: 'lead', name: 'X' }), null);
  assert.equal(standInSvg({ shape: 'sedan', paint: 'black', shot: 'roof', name: 'X' }), null);
});

test('body, colour and name mapping', () => {
  assert.equal(studioShape('Sedan/Saloon'), 'sedan');
  assert.equal(studioShape('Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)'), 'van');
  assert.equal(studioShape('Compact SUV'), 'suv');
  assert.equal(studioShape('Mid-size SUV'), 'suvlg');
  assert.equal(studioShape('Pickup truck'), 'suvlg');
  assert.equal(studioShape('Convertible'), 'roadster');
  assert.equal(studioShape('Hatchback/Liftback/Notchback'), 'compact');
  assert.equal(studioPaint('Black'), 'black');
  assert.equal(studioPaint('Summit White'), 'white');
  assert.equal(studioPaint('Mosaic Black Metallic'), 'black');
  assert.equal(studioPaint('Northsky Blue'), 'blue');
  assert.equal(studioPaint(null), 'grey');
  assert.equal(studioName('CR-V'), 'CR-V');
  assert.equal(studioName('<script>'), 'SCRIPT');
});

test('r33 letteringName: the word behind the car from the model', async () => {
  const { letteringName } = await import('./studio.ts');
  assert.equal(letteringName('CLA-Class'), 'CLA');
  assert.equal(letteringName('C-Class'), 'C CLASS');
  assert.equal(letteringName('A-Class'), 'A CLASS');
  assert.equal(letteringName('GLA-Class'), 'GLA');
  assert.equal(letteringName('AMG GT'), 'AMG GT');
  assert.equal(letteringName('CTS'), 'CTS');
  assert.equal(letteringName('CR-V'), 'CR-V');
  assert.equal(letteringName('F-150'), 'F-150');
  assert.equal(letteringName('C CLASS'), 'C CLASS', 'idempotent');
  assert.equal(letteringName('CLA CLASS'), 'CLA');
  assert.equal(letteringName('E-Class Cabriolet'), 'E CLASS', 'body styles are left out');
});

test('r40 letteringName: a short display name for the fleet\'s long models (owner, Nov 12: too long)', async () => {
  const { letteringName, LETTER_NAME_MAX } = await import('./studio.ts');
  const want: Record<string, string> = {
    'Mercedes-Benz GLC GLC43 AMG Coupe': 'GLC43 AMG',
    'Mercedes-Benz AMG GT GT53 4-Door Coupe': 'AMG GT 53',
    'Mercedes-Benz S-Class Maybach S580': 'MAYBACH S580',
    'Land Rover Range Rover Sport V8': 'RANGE ROVER SPORT',
    'BMW 4 Series M440i Gran Coupe': 'M440I',
    'Mercedes-Benz GLS Maybach GLS600': 'MAYBACH GLS600',
    '2024 Volkswagen Jetta Comfortline Sport': 'JETTA',
    'Chevrolet Corvette Stingray': 'CORVETTE',
    'Mercedes-Benz C-Class': 'C CLASS',
    'Mercedes-AMG GT': 'AMG GT'
  };
  for (const [k, v] of Object.entries(want)) {
    assert.equal(letteringName(k), v, k);
    assert.equal(letteringName(v), v, `${k}: idempotent`);
    assert.ok(letteringName(k).length <= LETTER_NAME_MAX);
  }
  assert.ok(letteringName('Some Very Long Model Name Of Many Words Indeed').length <= LETTER_NAME_MAX);
  assert.equal(letteringName('Coupe'), 'COUPE', 'never empty');
  assert.equal(letteringName(''), '');
});

test('r40: only the lead stand-in carries the name', () => {
  const lettered = (shot: string) => /font-weight="800"[^>]*font-size="\d+"[^>]*>CAMRY</.test(carShot(camry, shot, 1800, 1200));
  assert.equal(lettered('lead'), true);
  for (const shot of ['side', 'rear34', 'front', 'rear', 'dash', 'seats', 'wheel']) assert.equal(lettered(shot), false, shot);
});

test('r38: a long model name fits the wall panel: smaller, or two lines, never wider than the panel', () => {
  for (const n of ['MERCEDES-BENZ GLA-CLASS', '4 SERIES GRAN COUPE', 'GLA', 'RANGE ROVER SPORT', 'AMG GT 63 S E PERFORMANCE', 'ABCDEFGHIJKLMNOPQRSTUVWX']) {
    const { lines } = studioLettering(n);
    assert.ok(lines.length >= 1 && lines.length <= 2, n);
    assert.equal(lines.map((l) => l.text).join(' '), n);
    for (const l of lines) {
      assert.ok(l.length <= LETTER_MAX, `${n}: ${l.length}`);
      assert.ok(l.text.length * l.size * 0.7 <= LETTER_MAX + 1 || l.size === 56, `${n}: ${l.text} at ${l.size}`);
      assert.ok(l.y - l.size >= 300 && l.y < 690, `${n}: on the panel (${l.y})`);
    }
  }
  assert.equal(studioLettering('GLA').lines[0]!.size, 150);
  assert.equal(studioLettering('MERCEDES-BENZ GLA-CLASS').lines.length, 2);
  const svg = standInSvg({ shape: 'suv', paint: 'black', shot: 'lead', name: '4 Series Gran Coupe' })!;
  for (const m of svg.matchAll(/textLength="(\d+)"/g)) assert.ok(Number(m[1]) <= LETTER_MAX);
});
