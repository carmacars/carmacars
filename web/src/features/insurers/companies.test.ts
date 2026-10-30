import { test } from 'node:test';
import assert from 'node:assert/strict';
import { INSURANCE_COMPANIES, OTHER_INSURER, insurerSortKey, matchInsurer } from './companies.ts';

test('the insurers are in alphabetical order, each once', () => {
  const keys = INSURANCE_COMPANIES.map(insurerSortKey);
  assert.deepEqual(keys, [...keys].sort((a, b) => a.localeCompare(b)));
  assert.equal(new Set(keys).size, keys.length);
});

test('the list has the main Ontario auto insurers', () => {
  for (const n of ['Intact', 'Aviva', 'Desjardins', 'Allstate', 'TD Insurance', 'Belairdirect', 'The Co-operators', 'Economical', 'Definity', 'Wawanesa',
    'Gore Mutual', 'CAA Insurance', 'RBC Insurance', 'Sonnet', 'Travelers', 'Pembridge', 'Northbridge', 'Unica', 'Jevco', 'Echelon', 'Chubb', 'Peel Mutual',
    'Western Assurance', 'Primmum', 'Coachman', 'Old Republic', 'SGI Canada', 'Optimum', 'Square One']) assert.ok(INSURANCE_COMPANIES.includes(n), n);
  assert.ok(!INSURANCE_COMPANIES.includes(OTHER_INSURER));
});

test('a saved or typed name finds the list spelling; anything else is Other', () => {
  assert.equal(matchInsurer('td insurance'), 'TD Insurance');
  assert.equal(matchInsurer(' Co-operators '), 'The Co-operators');
  assert.equal(matchInsurer('BELAIRDIRECT'), 'Belairdirect');
  assert.equal(matchInsurer('Example Auto Insurance'), null);
  assert.equal(matchInsurer(''), null);
  assert.equal(matchInsurer(null), null);
});
