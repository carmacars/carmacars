import { test } from 'node:test';
import assert from 'node:assert/strict';
import { downloadName, isPdf, itemHref, shownKinds, validLink, versionLine, type Library } from './library.ts';

const lib: Library = { kinds: [
  { key: 'business_plan', label: 'Business plan', items: [{ id: 'a', title: 'Plan', kind: 'business_plan', version: 2, file_kind: 'pdf', updated_at: '2026-11-24T15:00:00Z', updated_on: '2026-11-24', link_url: null }] },
  { key: 'pitch_deck', label: 'Pitch deck', items: [{ id: 'b', title: 'Deck', kind: 'pitch_deck', version: 1, file_kind: 'link', updated_at: '', updated_on: '2026-11-20', link_url: 'https://carmacars.ca/investor/deck', archived: true }] },
  { key: 'feature_decks', label: 'Feature decks', items: [] }
] };

test('investors see only sections with documents; Admins see every section and archived items', () => {
  assert.deepEqual(shownKinds(lib).map((k) => k.key), ['business_plan']);
  assert.deepEqual(shownKinds(lib, true).map((k) => `${k.key}:${k.items.length}`), ['business_plan:1', 'pitch_deck:1', 'feature_decks:0']);
  assert.deepEqual(shownKinds(null), []);
});

test('a PDF opens through the signed-link route; a deck link opens itself, https only', () => {
  assert.equal(itemHref({ id: 'a', file_kind: 'pdf', link_url: null }), '/investor/documents/library/a');
  assert.equal(itemHref({ id: 'b', file_kind: 'link', link_url: 'https://carmacars.ca/investor/deck' }), 'https://carmacars.ca/investor/deck');
  assert.equal(itemHref({ id: 'c', file_kind: 'link', link_url: 'javascript:alert(1)' }), '/investor/documents/library/c');
});

test('the version line, the download name, the PDF check and the link rule', () => {
  assert.equal(versionLine({ version: 2, updated_on: '2026-11-24' }), 'Version 2, updated November 24, 2026');
  assert.equal(downloadName('CarmaCars business plan (2026)', 3), 'CarmaCars-business-plan-2026-v3.pdf');
  assert.equal(downloadName('***', 1), 'document-v1.pdf');
  assert.equal(isPdf(new TextEncoder().encode('%PDF-1.7 ...')), true);
  assert.equal(isPdf(new TextEncoder().encode('<html>')), false);
  assert.equal(validLink('https://carmacars.ca/investor/deck'), true);
  assert.equal(validLink('http://carmacars.ca'), false);
  assert.equal(validLink(`https://x.test/${'a'.repeat(500)}`), false);
});
