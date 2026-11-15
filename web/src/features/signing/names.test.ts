import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardNameMatches, initialsOf, nameTokens, sameName } from './names.ts';

test('names: the words of a name, accents and punctuation removed', () => {
  assert.deepEqual(nameTokens("  Zoë  O'Neil-Brown "), ['zoe', 'oneil', 'brown']);
  assert.deepEqual(nameTokens('ŁUKASZ Wróbel'), ['lukasz', 'wrobel']);
  assert.deepEqual(nameTokens(null), []);
});

test('names: the same person written differently matches', () => {
  assert.equal(sameName('  JOSÉ  maría García-López ', 'Jose Lopez'), true);
  assert.equal(sameName('Smith, John', 'John A. Smith'), true);
  assert.equal(sameName('J. Smith', 'John Smith'), true);
  assert.equal(sameName("Mary O'Neil", 'mary oneil'), true);
  assert.equal(sameName('Anne Marie Lee', 'AnneMarie Lee'), true);
  assert.equal(sameName('Nguyen Van An', 'An Nguyen'), true);
});

test('names: another person, one word alone or nothing does not match', () => {
  assert.equal(sameName('Jane Smith', 'John Smith'), false);
  assert.equal(sameName('Smith', 'John Smith'), false);
  assert.equal(sameName('', ''), false);
  assert.equal(sameName('Bob Smith', 'Robert Smith'), false);
});

test('names: initials are the first and the last word', () => {
  assert.equal(initialsOf('José María García-López'), 'JL');
  assert.equal(initialsOf('anna'), 'A');
  assert.equal(initialsOf(''), '');
});

test('card names: middle names, initials, shortened first names, accents, order and hyphens pass', () => {
  assert.equal(cardNameMatches('ALEX J SMITH', 'Alexander Smith'), true);
  assert.equal(cardNameMatches('M HUSSEIN-ALI', 'Mohammed Ali'), true);
  assert.equal(cardNameMatches('SMITH/JOHN', 'John Smith'), true);
  assert.equal(cardNameMatches('RENEE DUBE', 'Renée Dubé'), true);
  assert.equal(cardNameMatches('Maria Garcia Lopez', 'Maria Lopez'), true);
});

test('card names: another person or a nickname goes to staff review', () => {
  assert.equal(cardNameMatches('Jane Doe', 'John Smith'), false);
  assert.equal(cardNameMatches('A SMITH', 'Bob Smith'), false);
  assert.equal(cardNameMatches('BOB SMITH', 'Robert Smith'), false);
  assert.equal(cardNameMatches(null, 'Robert Smith'), false);
});
