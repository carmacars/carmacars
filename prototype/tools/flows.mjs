#!/usr/bin/env node
// Behaviour checks + state screenshots. Exits non-zero on any failed check.
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node tools/flows.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || '/opt/node22/lib/node_modules/playwright/index.mjs');
const { serve } = await import('./serve.mjs');
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'); const OUT = path.join(ROOT, 'shots');
const { COOKIES } = await import('./src/site.mjs');
const CONSENT = `try { sessionStorage.setItem('cc.cookies', JSON.stringify({ version: '${COOKIES.version}', choice: 'necessary_only', analytics: false })); } catch (e) {}`;
const server = await serve(4197); const BASE = 'http://127.0.0.1:4197/';
const browser = await chromium.launch(); const results = []; const errors = [];
const ok = (name, cond, extra = '') => { results.push([cond ? 'PASS' : 'FAIL', name, extra]); };
const shot = (page, name, full = false) => page.screenshot({ path: path.join(OUT, `state-${name}.png`), fullPage: full });
async function ctxPage(width, banner = false) { const ctx = await browser.newContext({ viewport: { width, height: width < 500 ? 740 : 900 }, reducedMotion: 'reduce' }); if (!banner) await ctx.addInitScript(CONSENT); const page = await ctx.newPage(); page.setDefaultTimeout(5000); page.on('console', (m) => { if (m.type() === 'error' && !/no-such-page/.test(m.location().url || '')) errors.push(m.text()); }); page.on('pageerror', (e) => errors.push(e.message)); return page; }

// ---- pricing: the worked examples in renter_billing_spec.md section 2
{
  const page = await ctxPage(1440); await page.goto(BASE + 'index.html');
  const r = await page.evaluate(() => { const P = CC.pricing; const rates = { daily: 100, weekend: 120, weekly: 560, monthly: 1800 };
    return { a: P.rental(rates, '2026-10-15', P.days('2026-10-15', '10:00', '2026-10-18', '10:00').days).amount, // Thu to Sun
      b: P.rental(rates, '2026-10-19', P.days('2026-10-19', '09:00', '2026-10-25', '09:00').days).amount, // Mon to Sun
      c: P.rental(rates, '2026-10-19', 10).amount, d: P.rental(rates, '2026-10-19', 30).amount, e: P.rental(rates, '2026-10-19', 15).amount,
      partDay: P.days('2026-10-15', '10:00', '2026-10-16', '10:30').days, min: P.days('2026-10-15', '10:00', '2026-10-15', '14:00').days, over: P.days('2026-10-15', '10:00', '2026-11-29', '10:00').over }; });
  ok('rate rule: Thu 10:00 to Sun 10:00 = $340', r.a === 340, r.a); ok('rate rule: Mon to Sun, 6 days capped at weekly = $560', r.b === 560, r.b);
  ok('rate rule: 10 days = $800', r.c === 800, r.c); ok('rate rule: 30 days = monthly $1,800', r.d === 1800, r.d); ok('rate rule: 15 days = $1,200', r.e === 1200, r.e);
  ok('billable days: part day rounds up', r.partDay === 2, r.partDay); ok('billable days: minimum 1', r.min === 1, r.min); ok('billable days: over 30 flagged', r.over === true);
  await page.context().close();
}

for (const width of [1440, 375]) {
  const tag = width;
  // ---- home search -> fleet
  let page = await ctxPage(width); await page.goto(BASE + 'index.html');
  await page.locator('.search [data-dr="from"]').focus(); await page.keyboard.press('Enter');
  ok(`[${tag}] home: date popover opens from the keyboard`, await page.locator('.popover:visible').count() === 1);
  // keyboard: focus lands in the grid; move right one day and pick, then 3 more days and pick
  await page.keyboard.press('ArrowRight'); await page.keyboard.press('Enter'); await page.keyboard.press('ArrowRight'); await page.keyboard.press('ArrowRight'); await page.keyboard.press('ArrowRight'); await page.keyboard.press('Enter');
  await shot(page, `home-datepicker-${tag}`);
  await page.keyboard.press('Escape');
  ok(`[${tag}] home: Escape closes the popover and returns focus`, !(await page.locator('.popover:visible').count()) && await page.evaluate(() => document.activeElement.matches('[data-dr]')));
  const v = await page.evaluate(() => [document.querySelector('.search input[name=from]').value, document.querySelector('.search input[name=to]').value]);
  ok(`[${tag}] home: keyboard picked Oct 16 to Oct 19`, v[0] === '2026-10-16' && v[1] === '2026-10-19', v.join(' '));
  await page.locator('.search label:has(input[value=delivery])').click(); await page.locator('.search__go').click(); await page.waitForURL(/fleet\.html\?/);
  await page.waitForTimeout(700);
  const count = await page.locator('[data-fleet-count]').textContent();
  ok(`[${tag}] fleet: dates carried over and availability applied`, /^Cars free Fri, Oct 16 to Mon, Oct 19$/.test(count.trim()), count);
  ok(`[${tag}] fleet: no fleet count is shown`, !/\d+ cars?\b/.test(await page.locator('.fleet-results__head').textContent()));
  ok(`[${tag}] fleet: the 2 hour turnaround makes the Corolla (back Oct 16, 10 a.m.) unavailable from 10 a.m.`, await page.locator('#fleet-grid > li[data-slug="toyota-corolla"]').evaluate((li) => li.classList.contains('is-booked')));
  await shot(page, `fleet-dates-${tag}`, true);
  // filters
  if (width < 1024) { await page.locator('[data-filters-open]').click(); await page.waitForTimeout(500); await shot(page, `fleet-filtersheet-${tag}`); }
  await page.locator('#filters label:has(input[value="SUV"])').click(); await page.locator('#filters label:has(input[name=trans][value=Manual])').click();
  if (width < 1024) { await page.locator('#filters [data-filters-count]').click(); await page.waitForTimeout(500); }
  ok(`[${tag}] fleet: empty state shows when nothing matches`, await page.locator('[data-fleet-empty]').isVisible());
  await shot(page, `fleet-empty-${tag}`);
  await page.locator('[data-fleet-empty] [data-clear]').click();
  ok(`[${tag}] fleet: clear filters restores results`, await page.locator('#fleet-grid').isVisible());
  await page.locator('select[name=sort]').selectOption('price-asc');
  const firstCar = await page.locator('#fleet-grid > li:not([hidden]) .car-card__name').first().textContent();
  ok(`[${tag}] fleet: sort by price puts the cheapest free car first`, /Elantra|Corolla/.test(firstCar), firstCar.trim());
  const href = await page.locator('#fleet-grid > li:not([hidden]) a').first().getAttribute('href');
  ok(`[${tag}] fleet: card links carry the dates`, /from=2026-10-16&to=2026-10-19/.test(href), href);
  await page.context().close();

  // ---- loading skeleton (motion on)
  { const ctx = await browser.newContext({ viewport: { width, height: 800 } }); await ctx.addInitScript(CONSENT); const p2 = await ctx.newPage(); await p2.goto(BASE + 'fleet.html?from=2026-11-24&to=2026-11-27'); await p2.waitForTimeout(120); ok(`[${tag}] fleet: skeleton shows while availability loads`, await p2.locator('[data-fleet-skeleton]').isVisible()); await p2.screenshot({ path: path.join(OUT, `state-fleet-loading-${tag}.png`) }); await p2.waitForTimeout(700); ok(`[${tag}] fleet: skeleton clears`, !(await p2.locator('[data-fleet-skeleton]').isVisible())); await ctx.close(); }

  // ---- car page: calendar + estimate
  page = await ctxPage(width); await page.goto(BASE + 'car-mercedes-benz-a220.html');
  ok(`[${tag}] car: booked day is disabled`, (await page.locator('[data-date="2026-10-18"]').getAttribute('aria-disabled')) === 'true');
  await page.locator('[data-booking] [data-date="2026-10-22"]').click(); await page.locator('[data-booking] [data-date="2026-10-25"]').click();
  await page.locator('label:has(input[name=deliver])').click(); await page.locator('#car-age').selectOption('21-25'); await page.waitForTimeout(500);
  // A220: Thu 95 + Fri 115 + Sat 115 = 325; delivery 100; young 3 x 20 = 60; subtotal 485; HST 63.05; total 548.05
  const total = await page.locator('[data-estimate] [data-total]').textContent();
  ok(`[${tag}] car: estimate uses the rate rule, fees and HST ($548.05)`, total === '$548.05', total);
  const book = await page.locator('.booking__est [data-book]').getAttribute('href');
  ok(`[${tag}] car: Request to book carries the choices`, /car=mercedes-benz-a220&from=2026-10-22&to=2026-10-25.*deliver=1.*age=21-25/.test(book), book);
  await page.locator('[data-booking]').scrollIntoViewIfNeeded(); await shot(page, `car-estimate-${tag}`, true);
  await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(300); await page.evaluate(() => document.querySelector('#need').scrollIntoView()); await page.waitForTimeout(900);
  ok(`[${tag}] car: sticky Request to book bar is on after scrolling`, await page.locator('.bookbar.is-on').isVisible());
  await shot(page, `car-bookbar-${tag}`);
  // crossing a booking is refused
  await page.goto(BASE + 'car-mercedes-benz-a220.html'); await page.locator('[data-booking] [data-date="2026-10-16"]').click(); await page.locator('[data-booking] [data-date="2026-10-20"]').click();
  ok(`[${tag}] car: a range across a booking is refused with a reason`, /cross another booking/.test(await page.locator('[data-booking] .cal__status').textContent()));
  // gallery
  await page.locator('[data-gallery-next]').click(); await page.waitForTimeout(500);
  ok(`[${tag}] car: gallery advances`, /2 \/ 8/.test(await page.locator('[data-gallery-count]').textContent()));
  await page.context().close();

  // ---- request flow
  page = await ctxPage(width); await page.goto(BASE + 'request.html?car=toyota-corolla&from=2026-11-02&to=2026-11-05&tf=10:00&tt=10:00&deliver=1');
  await page.locator('[data-step="1"] [data-next]').click();
  ok(`[${tag}] request: step 1 blocks on the missing delivery address`, await page.locator('[data-step="1"]').isVisible() && /delivery address/.test(await page.locator('[data-addr-deliver] .error').textContent()));
  await shot(page, `request-1-error-${tag}`, true);
  await page.fill('#rq-addr1', '100 Sample Street, Toronto'); await page.locator('[data-step="1"] [data-next]').click();
  ok(`[${tag}] request: moves to step 2`, await page.locator('[data-step="2"]').isVisible());
  await page.locator('[data-step="2"] [data-next]').click(); await shot(page, `request-2-errors-${tag}`, true);
  ok(`[${tag}] request: step 2 shows inline errors`, (await page.locator('[data-step="2"] .has-error').count()) >= 4);
  await page.fill('#rq-first', 'Sample'); await page.fill('#rq-last', 'Renter'); await page.fill('#rq-email', 'sample@example.com'); await page.fill('#rq-phone', '416 555 0100');
  await page.selectOption('#rq-dobm', '5'); await page.fill('#rq-dobd', '14'); await page.fill('#rq-doby', '2012'); await page.locator('[data-step="2"] [data-next]').click();
  ok(`[${tag}] request: under 18 is refused`, /18 or older/.test(await page.locator('[data-dob-field] .error').textContent()));
  await page.fill('#rq-doby', '2007'); await page.locator('[data-step="2"] [data-next]').click(); // 19 at pickup, Corolla allows it
  ok(`[${tag}] request: a 19 year old can continue on a car open to 18 to 20`, await page.locator('[data-step="3"]').isVisible());
  // saved progress survives a reload
  await page.reload(); await page.waitForTimeout(200);
  await page.goto(BASE + 'request.html'); await page.waitForTimeout(200);
  ok(`[${tag}] request: progress is saved and restored`, (await page.inputValue('#rq-first')) === 'Sample' && await page.locator('[data-step="3"]').isVisible() && await page.locator('[data-restored]').isVisible());
  await page.locator('[data-step="3"] [data-next]').click(); await shot(page, `request-3-errors-${tag}`, true);
  await page.locator('label:has(input[name=licClass][value=G2])').click(); await page.selectOption('#rq-licm', '6'); await page.selectOption('#rq-licy', '2028'); await page.locator('label.option:has(input[name=coverage][value="2"])').click();
  await page.locator('[data-step="3"] [data-next]').click();
  ok(`[${tag}] request: reaches review`, await page.locator('[data-step="4"]').isVisible());
  // Corolla Mon-Thu 3 x 59 = 177; delivery 75; young 18-20 3 x 35 = 105; subtotal 357; HST 46.41; total 403.41
  const t4 = await page.locator('[data-summary-total]').textContent();
  ok(`[${tag}] request: summary total with young driver fee ($403.41)`, t4 === '$403.41', t4);
  if (width < 1024) await page.evaluate(() => { document.querySelector('.req__sum').open = true; });
  await shot(page, `request-4-review-${tag}`, true);
  await page.locator('#request button[type=submit]').click();
  ok(`[${tag}] request: needs the confirmation tick`, /Tick this box/.test(await page.locator('[data-step="4"] .field .error').textContent()));
  await page.locator('label.check:has(input[name=agree])').click({ position: { x: 12, y: 12 } }); await page.locator('#request button[type=submit]').click(); await page.waitForURL(/confirmation\.html/);
  ok(`[${tag}] request: confirmation shows the request`, /Toyota Corolla/.test(await page.locator('[data-conf-rows]').textContent()) && /^R-\d{6}$/.test(await page.locator('[data-conf-ref]').textContent()));
  await shot(page, `confirmation-${tag}`, true);
  await page.context().close();


  // ---- owner's answers: every car takes 18+, several classes, turnaround, notice, address lookup, cookies
  page = await ctxPage(width); await page.goto(BASE + 'fleet.html');
  await page.evaluate(() => { const f = document.querySelector('#filters'); f.querySelector('[value="Convertible"]').checked = true; f.querySelector('[value="Pickup"]').checked = true; f.dispatchEvent(new Event('change')); });
  const multi = await page.$$eval('#fleet-grid > li:not([hidden])', (l) => l.map((x) => x.dataset.slug).sort().join(','));
  ok(`[${tag}] fleet: several classes at once show cars in any of them`, multi === 'ford-f-150,ford-mustang,mazda-mx-5', multi);
  await page.goto(BASE + 'car-mercedes-benz-a220.html');
  ok(`[${tag}] car: a day next to a booking is partly available`, await page.locator('[data-booking] [data-date="2026-10-19"]').evaluate((b) => b.classList.contains('is-part') && /free from 12:00 p\.m\./.test(b.getAttribute('aria-label'))));
  await page.locator('[data-booking] [data-date="2026-10-19"]').click(); await page.locator('[data-booking] [data-date="2026-10-21"]').click(); await page.waitForTimeout(300);
  ok(`[${tag}] car: pickup inside the 2 hour turnaround is flagged`, /free from 12:00 p\.m\./.test(await page.locator('[data-time-problem]').textContent()));
  await page.selectOption('#car-tf', '12:00'); await page.waitForTimeout(200);
  ok(`[${tag}] car: pickup at the end of the turnaround is fine`, !(await page.locator('[data-time-problem]').count()));
  await page.goto(BASE + 'car-porsche-911.html'); await page.locator('[data-booking] [data-date="2026-10-15"]').click(); await page.locator('[data-booking] [data-date="2026-10-16"]').click(); await page.selectOption('#car-tf', '10:00'); await page.waitForTimeout(200);
  ok(`[${tag}] car: pickup needs 2 hours' notice`, /at least 2 hours’ notice/.test(await page.locator('[data-time-problem]').textContent()));
  await page.selectOption('#car-age', '18-20'); await page.selectOption('#car-tf', '12:00'); await page.waitForTimeout(200);
  const est = await page.locator('[data-estimate]').textContent();
  ok(`[${tag}] car: an 18 year old can rent the 911, with its own young driver fee and no maximum`, /\$75 a day, no maximum/.test(est), est.slice(0, 120));
  await page.goto(BASE + 'request.html?car=chrysler-pacifica&from=2026-11-02&to=2026-11-05');
  ok(`[${tag}] request: the owner's location is offered for a car that has it`, await page.locator('[data-owner-opt]').first().isVisible());
  await page.locator('label.option:has(input[name=pickupAt][value=delivery])').click(); await page.fill('#rq-addr1', 'union');
  ok(`[${tag}] request: address lookup suggests while typing`, await page.locator('#rq-addr1-list [role=option]').first().isVisible());
  await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter');
  ok(`[${tag}] request: a suggestion can be chosen from the keyboard`, /Union Station/.test(await page.inputValue('#rq-addr1')));
  await page.context().close();
  page = await ctxPage(width, true); await page.goto(BASE + 'index.html');
  ok(`[${tag}] cookies: the banner shows on a first visit`, await page.locator('.cookie').isVisible());
  await shot(page, `cookie-banner-${tag}`);
  await page.locator('.cookie [data-ck-prefs]').click(); await page.waitForTimeout(300);
  ok(`[${tag}] cookies: preferences open with analytics off`, await page.locator('#cookie-prefs').isVisible() && !(await page.locator('#cookie-prefs [name=analytics_cookies]').isChecked()));
  await shot(page, `cookie-prefs-${tag}`);
  await page.locator('#cookie-prefs label:has([name=analytics_cookies])').click(); await page.locator('#cookie-prefs [data-ck-save]').click();
  ok(`[${tag}] cookies: the choice is saved and the banner goes`, !(await page.locator('.cookie').count()) && await page.evaluate(() => CC.cookieChoice().analytics === true));
  await page.goto(BASE + 'fleet.html'); ok(`[${tag}] cookies: remembered for the session`, !(await page.locator('.cookie').count()));
  await page.context().close();

  // ---- misc states
  page = await ctxPage(width); await page.goto(BASE + 'index.html');
  if (width < 1024) { await page.locator('.menu-btn').click(); await page.waitForTimeout(350); ok(`[${tag}] menu opens`, await page.locator('.menu-panel.is-open').isVisible()); await shot(page, `menu-${tag}`); await page.keyboard.press('Escape'); ok(`[${tag}] menu closes on Escape`, !(await page.locator('.menu-panel.is-open').count())); }
  await page.locator('.reviews .switch').scrollIntoViewIfNeeded(); await page.locator('.reviews .switch input').check(); ok(`[${tag}] reviews: populated state toggles`, await page.locator('.reviews__list').first().isVisible() && await page.locator('.greviews .reviews__list').isVisible()); await page.locator('.reviews').screenshot({ path: path.join(OUT, `state-reviews-populated-${tag}.png`) });
  await page.locator('.faq summary').first().click(); ok(`[${tag}] faq opens`, await page.locator('.faq details[open]').count() === 1);
  await page.goto(BASE + 'faq.html'); await page.fill('[data-faq-filter]', 'deposit'); ok(`[${tag}] faq filter narrows`, /answers?/.test(await page.locator('[data-faq-count]').textContent()));
  await page.goto(BASE + 'owners.html'); await page.locator('#apply button[type=submit]').click(); ok(`[${tag}] owner form validates`, (await page.locator('#apply .has-error').count()) >= 5); await page.locator('#apply').screenshot({ path: path.join(OUT, `state-owner-form-errors-${tag}.png`) });
  await page.goto(BASE + 'styleguide.html'); await page.locator('[data-modal-open="sg-modal"]').first().click(); await page.waitForTimeout(450); ok(`[${tag}] modal opens`, await page.locator('#sg-modal').isVisible()); await shot(page, `modal-${tag}`); await page.keyboard.press('Escape');
  await page.locator('[data-toast]').first().click(); ok(`[${tag}] toast shows`, await page.locator('.toast').isVisible());
  await page.locator('#portal').scrollIntoViewIfNeeded(); await page.locator('#portal').screenshot({ path: path.join(OUT, `state-portal-${tag}.png`) });
  await page.goto(BASE + 'investors.html'); ok(`[${tag}] investor page offers sign-in only`, /signed-in investors only/.test(await page.locator('main').textContent()) && !/return|yield|%/.test(await page.locator('main').textContent()));
  const res = await page.goto(BASE + 'no-such-page'); ok(`[${tag}] unknown URL serves the 404 page`, res.status() === 404 && /Wrong turn/.test(await page.locator('h1').textContent()));
  await page.context().close();
}
await browser.close(); server.close();
const fails = results.filter((r) => r[0] === 'FAIL');
for (const r of results) console.log(r[0], r[1], r[0] === 'FAIL' ? '-> got: ' + r[2] : '');
console.log(`\nchecks: ${results.length}, passed: ${results.length - fails.length}, failed: ${fails.length}; console errors: ${errors.length}`);
if (errors.length) console.log(errors.join('\n'));
process.exit(fails.length || errors.length ? 1 : 0);
