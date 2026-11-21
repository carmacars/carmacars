import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// r48 (docs/changes/2026-11-14-r48-fleet-calendar.md): the fleet calendar the Admin and the staff share, at 360 and 1280
// (each project runs both widths). Only the calendar scrolls sideways (the page never does); the car column keeps its
// width and stays put when the days scroll, the date header stays put when the cars scroll, today is marked, and no
// two bars of a car sit on top of each other.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
type Sql = ReturnType<typeof db>;

async function mkUser(sql: Sql, role: 'admin' | 'va') {
  const id = randomUUID(); const email = `${role}.fcal.${Date.now()}.${Math.floor(Math.random() * 1e4)}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${role === 'admin' ? 'Ada Admin' : 'Val Assistant'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'fleet')`;
  return email;
}
async function signIn(page: Page, email: string, path: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
  await page.goto(path, { waitUntil: 'networkidle' });
}

async function checkTimeline(page: Page, where: string, phone: boolean) {
  const cal = page.getByTestId('master-calendar');
  await expect(cal, where).toBeVisible();
  // a phone opens on the agenda: switch to the timeline
  const tl = cal.getByRole('button', { name: 'Timeline' });
  if (await tl.count()) await tl.click();
  const grid = cal.locator('.mcal__grid');
  await expect(grid, where).toBeVisible();
  await noOverflow(page);
  const m = await grid.evaluate((g) => {
    const r = g.getBoundingClientRect();
    const names = [...g.querySelectorAll('.mcal__name')].map((n) => n.getBoundingClientRect().width);
    const lanes = [...g.querySelectorAll('.mcal__lane')].map((l) => [...l.querySelectorAll('.mcal__item--top, .mcal__item--low')].map((b) => b.getBoundingClientRect()));
    const overlap = lanes.some((bars) => bars.some((a, i) => bars.some((b, j) => j > i && a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1)));
    return { inside: r.left >= -0.5 && r.right <= window.innerWidth + 0.5, names, overlap, today: g.querySelectorAll('.mcal__day.is-today').length, scrolls: g.scrollWidth > g.clientWidth };
  });
  expect(m.inside, `${where}: the calendar inside the window`).toBe(true);
  expect(m.overlap, `${where}: no bar on top of another`).toBe(false);
  expect(m.today, `${where}: today marked in the date header`).toBe(1);
  // on a phone two weeks never fit: the days scroll inside the calendar, not the page
  if (phone) expect(m.scrolls, `${where}: the days scroll inside the calendar`).toBe(true);
  if (m.names.length) {
    expect(Math.min(...m.names), `${where}: the car column never squeezed`).toBeGreaterThanOrEqual(130);
    expect(new Set(m.names.map(Math.round)).size, `${where}: one car column width`).toBe(1);
    // scroll the days: the car column stays where it was; scroll the cars: the date header stays at the top
    const before = await cal.locator('.mcal__name').first().boundingBox();
    const head0 = await cal.locator('.mcal__head').boundingBox();
    await grid.evaluate((g) => { g.scrollLeft = 400; g.scrollTop = 120; });
    const after = await cal.locator('.mcal__name').first().boundingBox();
    const head1 = await cal.locator('.mcal__head').boundingBox();
    expect(Math.abs(after!.x - before!.x), `${where}: sticky car column`).toBeLessThanOrEqual(1);
    expect(Math.abs(head1!.y - head0!.y), `${where}: sticky date header`).toBeLessThanOrEqual(1);
    await grid.evaluate((g) => { g.scrollLeft = 0; g.scrollTop = 0; });
  }
  // r48 follow-up: every car says whether it is free now; the corner counts the cars free today; the filter keeps only
  // the cars free every day shown (a car that cannot be booked is greyed out and never counted free)
  const rows = cal.locator('.mcal__row');
  const n = await rows.count();
  await expect(cal.getByTestId('cal-avail'), where).toHaveCount(n);
  // (r48 ops: a long fleet's groups fold, so the corner counts every car the filters keep, shown or folded)
  await expect(cal.getByTestId('cal-free-count'), where).toHaveText(/^\d+ of \d+ free today$/);
  const [free, total] = ((await cal.getByTestId('cal-free-count').textContent()) ?? '').match(/\d+/g)!.map(Number);
  expect(total, `${where}: the count covers the cars shown`).toBeGreaterThanOrEqual(n);
  expect(free, `${where}: free today at most all`).toBeLessThanOrEqual(total!);
  expect(await cal.locator('.mcal__row.is-off[data-free-all]').count(), `${where}: a car that cannot be booked is never free`).toBe(0);
  const freeAll = await cal.locator('.mcal__row[data-free-all="yes"]').count();
  await cal.getByTestId('cal-only-free').check();
  // (r48 ops: the free cars of a folded group show too once the filter is on, so there can be more than were in view)
  await expect(cal.locator('.mcal__row:not([data-free-all="yes"])'), `${where}: only the free cars`).toHaveCount(0);
  expect(await rows.count(), `${where}: every free car shown before is still shown`).toBeGreaterThanOrEqual(freeAll);
  await cal.getByTestId('cal-only-free').uncheck();
  await expect(rows, where).toHaveCount(n);
  await noOverflow(page);
}

test('fleet calendar: the Admin and Fleet staff at 360 and 1280, only the calendar scrolls sideways, sticky cars and dates', async ({ browser }, info) => {
  // both widths in one run: once is enough
  test.skip(info.project.name !== 'desktop-1440', 'runs 360 and 1280 itself');
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin');
  const fleet = await mkUser(sql, 'va');
  for (const [email, path] of [[admin, '/admin/calendar'], [fleet, '/staff/calendar']] as const) {
    for (const width of [360, 1280]) {
      const ctx = await browser.newContext({ viewport: { width, height: 800 }, hasTouch: width < 400, baseURL: test.info().project.use.baseURL });
      const page = await ctx.newPage();
      const errors = watch(page);
      await signIn(page, email, path);
      await checkTimeline(page, `${path} at ${width}`, width < 400);
      // every view keeps its days readable and the page still
      for (const view of ['week', 'month']) {
        await page.goto(`${path}?view=${view}`, { waitUntil: 'networkidle' });
        await checkTimeline(page, `${path} ${view} at ${width}`, width < 400);
      }
      expect(errors, path).toEqual([]);
      await ctx.close();
    }
  }
  await sql.end();
});
