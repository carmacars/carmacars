import { test } from 'node:test';
import assert from 'node:assert/strict';
import { crossSiteRefusal, crossSiteWriteRefused, unusedFrameworkPath } from './request-guard.ts';

const SITE = 'https://carmacars.ca';

test('a write from a page of this site passes (apex, www, and a server action with its Origin)', () => {
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/account/profile`, SITE, 'same-origin'), false);
  assert.equal(crossSiteWriteRefused('POST', 'https://www.carmacars.ca/staff', 'https://www.carmacars.ca', 'same-origin'), false);
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/book/x`, 'https://www.carmacars.ca', 'same-site'), false);
  assert.equal(crossSiteWriteRefused('DELETE', 'http://localhost:3000/api/storage/a', 'http://localhost:3000', null), false);
});

test('a write from another site is refused, whatever the route', () => {
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/api/view-as/exit`, 'https://evil.example', 'cross-site'), true);
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/admin/settings`, 'https://evil.example', null), true);
  assert.equal(crossSiteWriteRefused('PUT', `${SITE}/api/storage/a`, 'https://carmacars.ca.evil.example', null), true);
  // no Origin but the browser says cross-site (an older browser's form post)
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/api/help`, null, 'cross-site'), true);
  // an opaque origin from a sandboxed frame elsewhere
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/api/help`, 'null', 'cross-site'), true);
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/api/help`, 'null', null), true);
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/api/help`, 'not a url', null), true);
});

test('reads and senders that sign their requests are never refused here', () => {
  assert.equal(crossSiteWriteRefused('GET', `${SITE}/cars`, 'https://evil.example', 'cross-site'), false);
  assert.equal(crossSiteWriteRefused('HEAD', `${SITE}/cars`, 'https://evil.example', 'cross-site'), false);
  for (const p of ['/api/webhooks/stripe', '/api/webhooks/twilio/voice', '/api/inbound/turo', '/api/tracker/ingest', '/api/jobs/pdf', '/api/oauth/token', '/api/mcp', '/api/email/send', '/api/unsubscribe'])
    assert.equal(crossSiteWriteRefused('POST', `${SITE}${p}`, 'https://claude.ai', 'cross-site'), false, p);
  // a prefix without a slash covers only that path and its children
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/api/mcpx`, 'https://evil.example', null), true);
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/api/unsubscribe-all`, 'https://evil.example', null), true);
  // no Origin and no fetch metadata (a server-to-server call, curl): the route's own checks decide
  assert.equal(crossSiteWriteRefused('POST', `${SITE}/api/help`, null, null), false);
});

test('the refusal is a plain 403 that is never cached', async () => {
  const r = crossSiteRefusal({ 'X-Frame-Options': 'DENY' });
  assert.equal(r.status, 403);
  assert.equal(r.headers.get('cache-control'), 'no-store');
  assert.equal(r.headers.get('x-frame-options'), 'DENY');
  assert.match(await r.text(), /another website/);
});

test('the image optimizer the site never uses answers 404', () => {
  assert.equal(unusedFrameworkPath('/_next/image'), true);
  assert.equal(unusedFrameworkPath('/_next/image/'), true);
  assert.equal(unusedFrameworkPath('/_next/static/chunks/a.js'), false);
  assert.equal(unusedFrameworkPath('/images/car.jpg'), false);
});
