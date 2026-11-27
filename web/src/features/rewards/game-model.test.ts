import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gameLine, pointsWhere } from './game-model.ts';

test('the line under Play: one a day, several, played, off', () => {
  assert.equal(gameLine({ on: true, left: 1, cap: 1 }), 'One game a day. Every game wins points.');
  assert.equal(gameLine({ on: true, left: 2, cap: 3 }), '2 of 3 games left today. Every game wins points.');
  assert.match(gameLine({ on: true, left: 0, cap: 1 }), /Come back tomorrow/);
  assert.equal(gameLine({ on: false, left: 1, cap: 1 }), 'The games are off for now.');
});

test('where the points go: the account, saved for later, or none for a test account', () => {
  assert.match(pointsWhere({ has_account: true, waiting: 0, test: false }, 'renter'), /Rewards account/);
  assert.match(pointsWhere({ has_account: false, waiting: 75, test: false }, 'owner'), /^75 points are saved/);
  assert.match(pointsWhere({ has_account: false, waiting: 0, test: true }, 'staff'), /earns no points/);
});
