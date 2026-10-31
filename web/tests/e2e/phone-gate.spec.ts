import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// The phone number box (migration 0280) end to end, at 375 and 1440: what a crawler gets (every photo in the HTML and
// the JSON-LD, no box), dates picked freely, the full availability behind the box with the code by text (the fake line;
// the code read from the local mailbox) and the dates kept, the gallery past the free photos (Escape closes and gives
// the focus back; the number given goes to the photo tapped), the device remembered, the number on Renter leads, and
// the one-press switches turning a box off. The box's settings are part of the cached pages, so they are changed the way
// an Admin does (Settings, Phone number box), which rebuilds the pages.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const number = () => `416${2 + Math.floor(Math.random() * 8)}${String(Math.floor(Math.random() * 1e6)).padStart(6, '0')}`;
const GOOGLEBOT = 'Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)';

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[\u2013\u2014]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `pg.admin.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Gita Gate')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function codeFor(sql: Sql, phone: string): Promise<string> {
  for (let i = 0; i < 40; i++) {
    const [m] = await sql`select body from local_auth.mailbox where to_phone = ${phone} and subject = 'Text: phone number box code' order by id desc limit 1`;
    const c = /code: (\d{6})\./.exec(String(m?.body ?? ''))?.[1];
    if (c) return c;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`no code texted to ${phone}`);
}
/** A car on the site with at least `min` photos (read from its page, as a visitor sees it). */
async function carWithPhotos(page: Page, min: number): Promise<{ slug: string; photos: number }> {
  const list = await (await page.request.get('/cars')).text();
  const slugs = [...new Set([...list.matchAll(/href="\/cars\/([a-z0-9-]+)"/g)].map((m) => m[1]!))].slice(0, 25);
  for (const slug of slugs) {
    const html = await (await page.request.get(`/cars/${slug}`)).text();
    const n = Number(/aria-label="1 of (\d+)"/.exec(html)?.[1] ?? 0);
    if (n >= min) return { slug, photos: n };
  }
  throw new Error(`no car with ${min} photos`);
}
/** Two taps on Next photo: to the third photo (past the 2 free ones in this test). */
async function toThird(page: Page) {
  const next = page.getByRole('button', { name: 'Next photo' });
  await next.click();
  await expect(page.locator('.gallery__count b')).toHaveText(new RegExp('^2 / '));
  await next.click();
}
const iso = (days: number) => new Date(Date.now() + days * 86400_000).toISOString().slice(0, 10);

/** As an Admin: the box settings from the database, then one press on a switch so the pages are rebuilt with them. */
async function setBoxes(browser: Browser, sql: Sql, admin: { email: string }, values: { free?: number; verify?: boolean; gallery: boolean; dates: boolean }) {
  await sql`update program_settings set phone_gate_free_photos = ${values.free ?? 2}, phone_gate_verify = ${values.verify ?? true}, phone_gate_request = false,
    phone_gate_gallery = ${!values.gallery}, phone_gate_dates = ${values.dates}`;
  const page = await ctx(browser, false);
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(admin.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 60_000 });
  await page.goto('/admin/settings/phone-gate', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('gate-state-gallery')).toHaveText(values.gallery ? 'Off' : 'On');
  await page.getByTestId('gate-switch-gallery').click();
  await expect(page.getByTestId('gate-state-gallery')).toHaveText(values.gallery ? 'On' : 'Off');
  await expect(page.getByTestId('gate-state-dates')).toHaveText(values.dates ? 'On' : 'Off');
  await page.context().close();
}

test.describe.configure({ mode: 'serial' });

test('the phone number box: crawlers see every photo; dates stay open; full availability and more photos after the number (code by text); switches off', async ({ browser }, info) => {
  test.setTimeout(300_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits where key like 'phone-gate%'`;
  const admin = await mkAdmin(sql);
  try {
    await setBoxes(browser, sql, admin, { gallery: true, dates: true, free: 2, verify: true });
    const page = await ctx(browser, phone);
    const car = await carWithPhotos(page, 3);

    // ---------------------------------------------------------------- crawlers: everything in the HTML, no box
    const bot = await page.request.get(`/cars/${car.slug}`, { headers: { 'user-agent': GOOGLEBOT } });
    const html = await bot.text();
    expect([...html.matchAll(/<li aria-label="\d+ of (\d+)"/g)].length, 'every photo in the server HTML').toBe(car.photos);
    const ld = [...html.matchAll(/<script type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]!).join(' ');
    expect(ld).toContain('"image"');
    expect(html).not.toContain('data-testid="phone-gate"');

    // ---------------------------------------------------------------- dates: picking them is open; the full availability asks
    const from = iso(70), to = iso(73);
    await page.goto(`/cars/${car.slug}?from=${from}&to=${to}`, { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await expect(page.getByTestId('see-full-availability')).toBeVisible();
    const day = page.locator('.booking__cal .cal__day:not([disabled])').nth(10);
    await day.click();
    await expect(page.getByTestId('phone-gate')).toBeHidden();
    // back to the dates of the link (the click started a new range): the dates picked are what must survive the box
    await page.goto(`/cars/${car.slug}?from=${from}&to=${to}`, { waitUntil: 'networkidle' });
    const before = await page.locator('.car-top').boundingBox();
    await page.getByTestId('see-full-availability').click();
    const box = page.getByTestId('phone-gate');
    await expect(box).toBeVisible();
    await expect(box).toContainText('Put your phone number in to see full availability');
    await expect(box.getByLabel('Mobile number')).toBeFocused();
    await expect(page.getByTestId('phone-gate-deals')).not.toBeChecked();
    await check(page, 'the box');
    const n = number();
    await page.getByTestId('phone-gate-number').pressSequentially(n);
    await expect(page.getByTestId('phone-gate-number')).toHaveValue(`(${n.slice(0, 3)}) ${n.slice(3, 6)}-${n.slice(6)}`);
    await page.getByTestId('phone-gate-continue').click();
    await expect(page.getByTestId('phone-gate-sent')).toBeVisible();
    await page.getByTestId('phone-gate-code').fill(await codeFor(sql, `+1${n}`));
    await expect(box).toBeHidden();
    await expect(page.getByTestId('full-availability')).toContainText('Days already booked are crossed out.');
    await expect(page).toHaveURL(new RegExp(`from=${from}&to=${to}`));
    expect((await page.locator('.car-top').boundingBox())?.height, 'no layout shift above the dates').toBe(before?.height);
    // the number is a lead staff see, a transactional contact, no marketing consent
    const [lead] = await sql`select g.consent_source, g.marketing_opt_in, g.verified_at is not null as verified, l.source from phone_gate_contacts g join leads l on l.id = g.lead_id where g.phone = ${'+1' + n}`;
    expect(lead).toMatchObject({ consent_source: 'phone_gate', marketing_opt_in: false, verified: true, source: 'unfinished_form' });
    // the same device: no box again, the gallery too
    await page.reload({ waitUntil: 'networkidle' });
    await expect(page.getByTestId('full-availability')).toContainText('Days already booked are crossed out.');
    await toThird(page);
    await expect(page.getByTestId('phone-gate')).toBeHidden();
    await expect(page.locator('.gallery__count b')).toHaveText(new RegExp(`^3 / ${car.photos}$`));
    await page.context().close();

    // ---------------------------------------------------------------- the gallery: past the free photos, Escape, then the photo tapped
    const g = await ctx(browser, phone);
    await g.goto(`/cars/${car.slug}`, { waitUntil: 'networkidle' });
    await acceptCookies(g);
    const next = g.getByRole('button', { name: 'Next photo' });
    await next.click();
    await expect(g.locator('.gallery__count b')).toHaveText(new RegExp('^2 / '));
    await expect(g.getByTestId('phone-gate')).toBeHidden();
    await next.click();
    await expect(g.getByTestId('phone-gate')).toContainText('Put your phone number in to see more photos');
    await check(g, 'the box on the gallery');
    await g.keyboard.press('Escape');
    await expect(g.getByTestId('phone-gate')).toBeHidden();
    await expect(next).toBeFocused();
    await expect(g.locator('.gallery__count b')).toHaveText(new RegExp('^2 / '));
    await next.click();
    const m = number();
    await g.getByTestId('phone-gate-number').fill(m);
    await g.getByTestId('phone-gate-deals').check();
    await g.getByTestId('phone-gate-continue').click();
    await g.getByTestId('phone-gate-code').fill('000000');
    await expect(g.getByText(/That code does not match/)).toBeVisible();
    await g.getByTestId('phone-gate-code').fill(await codeFor(sql, `+1${m}`));
    await expect(g.getByTestId('phone-gate')).toBeHidden();
    await expect(g.locator('.gallery__count b')).toHaveText(new RegExp(`^3 / ${car.photos}$`));
    const [mk] = await sql`select marketing_opt_in, marketing_text from phone_gate_contacts where phone = ${'+1' + m}`;
    expect(mk?.marketing_opt_in).toBe(true);
    expect(String(mk?.marketing_text)).toContain('Also text me deals');
    await noOverflow(g);
    await g.context().close();
    const [c] = await sql`select (sum(shown) >= 3 and sum(given) >= 2 and sum(closed) >= 1)::boolean ok from phone_gate_daily where day = (now() at time zone 'America/Toronto')::date and gate <> 'all'`;
    expect(c?.ok, 'counted: shown, given, closed').toBe(true);

    // ---------------------------------------------------------------- the switches off: no box anywhere
    await setBoxes(browser, sql, admin, { gallery: false, dates: false, free: 2, verify: true });
    const o = await ctx(browser, phone);
    await o.goto(`/cars/${car.slug}`, { waitUntil: 'networkidle' });
    await acceptCookies(o);
    await expect(o.getByTestId('see-full-availability')).toHaveCount(0);
    await toThird(o);
    await expect(o.getByTestId('phone-gate')).toBeHidden();
    await expect(o.locator('.gallery__count b')).toHaveText(new RegExp(`^3 / ${car.photos}$`));
    await o.context().close();
  } finally {
    // the defaults again (more photos after 6 and the full availability on, the code off), with the pages rebuilt
    await setBoxes(browser, sql, admin, { gallery: true, dates: true, free: 6, verify: false }).catch(() => undefined);
    await sql.end();
  }
});
