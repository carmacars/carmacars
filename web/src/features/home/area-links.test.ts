import { test } from 'node:test';
import assert from 'node:assert/strict';
import { homeAreaLinks, type AreaPage } from './area-links.ts';

const P = (slug: string, kind: AreaPage['kind'], name: string, indexable = true): AreaPage => ({ slug, kind, name, path: `/car-rental/${slug}`, indexable });
test('2350: home links to the indexable landing pages, Toronto first, never a page that is not indexable', () => {
  const r = homeAreaLinks([P('markham', 'location', 'Markham'), P('toronto', 'location', 'Toronto'), P('ajax', 'location', 'Ajax (Durham)'),
    P('vaughan', 'location', 'Vaughan', false), P('suv-rental', 'use', 'SUV rental'), P('monthly', 'use', 'Monthly rental'),
    { slug: 'x', kind: 'location', name: 'X', path: '/elsewhere/x', indexable: true }]);
  assert.deepEqual(r.places.map((p) => p.slug), ['toronto', 'ajax', 'markham']);
  assert.deepEqual(r.uses.map((p) => p.slug), ['monthly', 'suv-rental']);
  assert.equal(homeAreaLinks([P('a', 'location', 'A'), P('b', 'location', 'B')], { places: 1, uses: 0 }).places.length, 1);
});
