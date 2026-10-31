import { test } from 'node:test';
import assert from 'node:assert/strict';
import { OUT_OF_SCOPE, allowLines, deepOutOfScope, inCrawlScope } from './crawl-scope.ts';
import { cpuGuard, isCrawler, shield } from './bot-shield.ts';

// Release 23: the crawl scope (Worker CPU at 36 times its allowance from crawlers walking trillions of addresses).
const landing = new Set(['/car-rental/toronto', '/car-rental/airport']);

test('crawl scope: the fixed pages, the fleet, the landing pages and the vehicle tree down to the trim are in', () => {
  for (const p of ['/', '/cars', '/cars/2021-honda-civic-abc', '/cars/honda', '/cars/honda/civic', '/cars/honda/civic/2021', '/cars/honda/civic/2021/ex',
    '/car-rental', '/car-rental/toronto', '/guides/tolls', '/delivery', '/places', '/makes']) assert.equal(inCrawlScope(p, landing), true, p);
});

test('crawl scope: places, colours, search terms, for sale and service places are out', () => {
  for (const p of ['/cars/audi/a4/2021/progressiv/plantation-fl', '/cars/audi/a4/2021/progressiv/plantation-fl/red', '/t/buffing/audi/a4/2021',
    '/buy/honda', '/buy', '/car-rental/weekly/toronto', '/car-rental/some-town-oh', '/detailing/ceramic/toronto', '/body-shop/dent/coxhuaco-ii-hid', '/places/12']) {
    assert.equal(inCrawlScope(p, landing), false, p);
  }
  assert.equal(deepOutOfScope('/car-rental/some-town-oh'), false, 'a one-segment place page is left to robots.txt at the edge');
});

test('robots lines: the trees disallowed, each landing page allowed exactly', () => {
  assert.ok(OUT_OF_SCOPE.includes('/car-rental/'));
  assert.deepEqual(allowLines(['/car-rental/toronto', '/guides/x', '/car-rental/airport']), ['/car-rental/airport$', '/car-rental/toronto$']);
});

test('edge, Core scope: a crawler outside the scope gets 403, a person never', () => {
  const bot = 'Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)';
  assert.deepEqual(shield('GET', 'https://carmacars.ca/t/buffing/audi/a4/2021/progressiv/plantation-fl/red', bot, true), { kind: 'refuse', reason: 'scope' });
  assert.deepEqual(shield('GET', 'https://carmacars.ca/cars/honda/civic/2021/ex', bot, true), { kind: 'pass' });
  assert.deepEqual(shield('GET', 'https://carmacars.ca/t/buffing/audi', 'Mozilla/5.0 (iPhone) Safari/605', true), { kind: 'pass' });
  assert.equal(isCrawler(bot), true);
  assert.equal(isCrawler('Mozilla/5.0 (iPhone) Safari/605'), false);
});

test('edge, Full scope (the default): every public page is open to crawlers', () => {
  const bot = 'Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)';
  for (const p of ['/t/buffing/audi/a4/2021/progressiv/plantation-fl/red', '/buy/honda/civic', '/places/toronto', '/cars/honda/civic/2021/ex/toronto'])
    assert.deepEqual(shield('GET', `https://carmacars.ca${p}`, bot), { kind: 'pass' }, p);
});

test('CPU guard: crawlers on catalog pages only, only while the flag is up', () => {
  const bot = 'Googlebot/2.1 (+http://www.google.com/bot.html)';
  assert.equal(cpuGuard('GET', '/cars/honda/civic', bot, true), true);
  assert.equal(cpuGuard('GET', '/cars/honda/civic', bot, false), false);
  assert.equal(cpuGuard('GET', '/cars/2021-honda-civic-abc', bot, true), false, 'a fleet car page');
  assert.equal(cpuGuard('GET', '/', bot, true), false);
  assert.equal(cpuGuard('GET', '/cars/honda/civic', 'Mozilla/5.0 (Macintosh) Chrome/130', true), false, 'a person');
  // the Full scope's programmatic trees are held too
  for (const p of ['/t/car-hire/toronto', '/buy/honda/civic', '/detailing/toronto', '/body-shop/toronto', '/places/toronto'])
    assert.equal(cpuGuard('GET', p, bot, true), true, p);
});
