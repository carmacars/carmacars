import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { carShot, standInSvg, studioName, studioPaint, studioShape } from './studio.ts';

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
  assert.equal(letteringName('E-Class Cabriolet'), 'E CLASS CABRIOLET');
});
