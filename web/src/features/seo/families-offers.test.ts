// r50 hotfix 2 (the owner, repeated): every SEO page family carries every lead offer and its detail blocks. A family's
// route, followed to the component that renders it, must render the services module (whose lead offers are tested in
// features/services/catalog.test.ts) and the family's detail block: the place details (DepthSections: transit, parking,
// fuel prices) on place pages, the figures (SpecsTable or StatsBlock, and DepthSections on our cars) on vehicle pages.
// Reads the source files: a family that drops either fails here.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const src = (p: string) => readFileSync(new URL(`../../${p}`, import.meta.url), 'utf8');
const has = (files: string[], re: RegExp) => files.some((f) => re.test(src(f)));
const PROMO = /<ServicePromo\b/;
const PLACE = /<DepthSections\b/;
const FIGURES = /<SpecsTable\b|<StatsBlock\b/;
// Questions (parts.tsx) renders the module on every vehicle page

const FAMILIES: Array<{ name: string; route: string; via: string[]; detail?: RegExp }> = [
  { name: '/car-rental', route: 'app/car-rental/page.tsx', via: [] },
  { name: '/car-rental/<place> and landing pages', route: 'app/car-rental/[slug]/page.tsx', via: ['features/places/HubPage.tsx'], detail: PLACE },
  { name: '/car-rental/<term>/<place>', route: 'app/car-rental/[slug]/[place]/page.tsx', via: ['features/places/route.tsx', 'features/places/HubPage.tsx'], detail: PLACE },
  { name: '/t/<term>/...', route: 'app/t/[...seg]/page.tsx', via: ['features/vehicles/twin.tsx', 'features/vehicles/parts.tsx'], detail: FIGURES },
  { name: '/buy/...', route: 'app/buy/[[...seg]]/page.tsx', via: ['features/vehicles/buy-index.tsx', 'features/vehicles/sale-hub.tsx', 'features/places/route.tsx', 'features/places/HubPage.tsx', 'features/vehicles/twin.tsx', 'features/vehicles/parts.tsx'], detail: FIGURES },
  { name: '/places', route: 'app/places/[[...page]]/page.tsx', via: [] },
  { name: '/body-shop', route: 'app/body-shop/page.tsx', via: ['features/places/ServicePage.tsx'] },
  { name: '/body-shop/<term>/<place>', route: 'app/body-shop/[term]/[place]/page.tsx', via: ['features/places/route.tsx', 'features/places/HubPage.tsx'], detail: PLACE },
  { name: '/detailing', route: 'app/detailing/page.tsx', via: ['features/places/ServicePage.tsx'] },
  { name: '/detailing/<term>/<place>', route: 'app/detailing/[term]/[place]/page.tsx', via: ['features/places/route.tsx', 'features/places/HubPage.tsx'], detail: PLACE },
  { name: '/cars/<slug> (our cars and the make pages)', route: 'app/cars/[slug]/page.tsx', via: ['features/vehicles/views.tsx', 'features/vehicles/parts.tsx'], detail: /<DepthSections\b/ },
  { name: '/cars/<make>/<model>/... (model, year, trim, place, colour)', route: 'app/cars/[slug]/[...rest]/page.tsx', via: ['features/vehicles/views.tsx', 'features/vehicles/deep.tsx', 'features/vehicles/parts.tsx'], detail: FIGURES },
  { name: '/trackers', route: 'app/trackers/page.tsx', via: ['features/trackers/TrackerPage.tsx'] },
  { name: '/chauffeur', route: 'app/chauffeur/page.tsx', via: [] }
];

test('r50 hotfix 2: every SEO page family renders the offers module and its detail block', () => {
  for (const f of FAMILIES) {
    const files = [f.route, ...f.via];
    // each file on the path is imported by the route or by another file of the path
    const name = (x: string) => x.split('/').pop()!.replace(/\.tsx?$/, '');
    for (const x of f.via) assert.ok(files.some((y) => y !== x && (src(y).includes(x.replace(/^/, '@/').replace(/\.tsx?$/, '')) || src(y).includes(`./${name(x)}'`))),
      `${f.name}: ${x} is on the route's path`);
    assert.ok(has(files, PROMO), `${f.name}: the offers module`);
    if (f.detail) assert.ok(has(files, f.detail), `${f.name}: the detail block`);
  }
});

test('the place details carry transit, parking and fuel prices; the vehicle figures a full tank or charge', () => {
  const depth = src('features/seo/depth.ts');
  for (const re of [/id: 'logistics'/, /id: 'parking'/, /GO station/, /we price gas at/, /A full tank/, /A full charge/]) assert.match(depth, re);
  assert.match(src('features/vehicles/content.ts'), /add\('A full charge'/);
  assert.match(src('features/vehicles/parts.tsx'), /<ServicePromo bare pageKey=\{title\} \/>/, 'every lead offer on the vehicle pages, not four');
});
