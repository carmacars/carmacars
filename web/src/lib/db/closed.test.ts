import test from 'node:test';
import assert from 'node:assert/strict';
import { isClosedConnection } from './closed.ts';

test('a closed connection is told from a SQL error', () => {
  assert.equal(isClosedConnection(Object.assign(new Error('write CONNECTION_CLOSED 127.0.0.1:54322'), { code: 'CONNECTION_CLOSED' })), true);
  assert.equal(isClosedConnection(new TypeError('This socket has been closed.')), true);
  assert.equal(isClosedConnection(Object.assign(new Error('read ECONNRESET'), { code: 'ECONNRESET' })), true);
  assert.equal(isClosedConnection(Object.assign(new Error('duplicate key'), { code: '23505' })), false);
  assert.equal(isClosedConnection(null), false);
});
