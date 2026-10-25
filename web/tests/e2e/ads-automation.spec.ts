import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Advertising automation (docs/changes/2026-10-25-advertising-automation.md, migration 0167): an Admin writes a Kijiji ad
// for a car (title, text, tracked link, photo order), records it as posted; a rate change marks the ad and opens a task;
// "Mark the ad updated" closes it; the week's social drafts are written, approved and marked posted by hand; the bookings
// by channel report and the Meta publishing page (off) show; an owner recruitment lead gets no message without consent,
// a logged yes on a call allows a text, which goes with the STOP line. Fictional people only; the car is the test's own.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 120_000 });
}
const dialog = (page: Page) => page.locator('dialog[open]');

test('ads automation: listing text, posted ad and its update task, social drafts, the report, owner recruitment with consent', async ({ page }) => {
  test.setTimeout(600_000);
  const errors = watch(page);
  const sql = db();
  const id = randomUUID(); const email = `admin.ads.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Morgan Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  // the test's own company car, on the site with its rates
  const vin = `3AXMX${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
  const [made] = await sql`select app.vehicle_add(${id}, ${sql.json({ supply_type: 'company', vin, plate: `AD${tag().toUpperCase()}`, year: 2024, make: 'Kia', model: `K5 ${tag()}`,
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as r`;
  const car = (made!.r as { vehicle_id: string }).vehicle_id;
  await sql`update vehicle_listings set status = 'published' where vehicle_id = ${car} and status <> 'published'`;
  const [v] = await sql`select car_code from vehicles where id = ${car}`;
  const code = (v!.car_code as string | null) ?? '';

  try {
    // ---------------------------------------------------------------- the listing text (Kijiji)
    await signIn(page, email, `/admin/marketing/listings?car=${car}&channel=kijiji`);
    await expect(page.getByTestId('ads-text')).toBeVisible({ timeout: 60_000 });
    await expect(page.getByTestId('ads-title')).toHaveValue(/Kia K5.*\$100/i);
    expect((await page.getByTestId('ads-title').inputValue()).length).toBeLessThanOrEqual(64);
    await expect(page.getByTestId('ads-price')).toHaveValue('From $100 a day, $700 a week, $3,000 for 30 days, plus HST.');
    const link = await page.getByTestId('ads-link').inputValue();
    expect(link).toContain('utm_source=kijiji');
    expect(link).toContain('utm_medium=classified');
    if (code) expect(link).toContain(`utm_campaign=${code}`);
    await expect(page.getByTestId('ads-body')).toHaveValue(/For rent by the day, week or month\./);
    await expect(page.getByTestId('ads-body')).toHaveValue(/\$300 refundable deposit taken at pickup\./);
    expect(await page.getByTestId('ads-body').inputValue()).not.toMatch(/—|18122211/);
    await axe(page, 'listings 1440');
    await page.setViewportSize({ width: 375, height: 900 });
    await axe(page, 'listings 375');
    await page.setViewportSize({ width: 1440, height: 900 });

    // recorded as posted
    await page.getByTestId('ads-mark-posted').click();
    await dialog(page).getByLabel('The ad\'s address (https://...)').fill(`https://www.kijiji.ca/v-cars/test/${tag()}`);
    await page.getByTestId('ads-mark-posted-submit').click();
    await expect.poll(async () => (await sql`select count(*)::int as n from ad_postings where vehicle_id = ${car} and channel = 'kijiji' and status = 'live'`)[0]!.n, { timeout: 60_000 }).toBe(1);

    // ---------------------------------------------------------------- a rate change: the ad needs updating, a task opens
    await sql`select app.set_rate_card(${car}, 12000, 12000, 70000, 300000, now(), ${id}, ${sql.json({ deposit_cents: 30000 })})`;
    await expect.poll(async () => (await sql`select needs_update from ad_postings where vehicle_id = ${car} and channel = 'kijiji' and status = 'live'`)[0]?.needs_update, { timeout: 30_000 }).toBe(true);
    const [task] = await sql`select t.status, t.queue, t.detail from ad_postings a join tasks t on t.id = a.update_task_id where a.vehicle_id = ${car} and a.channel = 'kijiji'`;
    expect(task?.status).toBe('open');
    expect(task?.queue).toBe('sales');
    expect(String(task?.detail)).toContain('New price line: From $120 a day');
    await page.goto('/admin/marketing/ads?status=needs_update', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('ads-update-kijiji').first()).toBeVisible({ timeout: 30_000 });
    await axe(page, 'posted ads');
    await page.goto(`/admin/marketing/listings?car=${car}&channel=kijiji`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('ads-needs-update')).toContainText('Daily rate $100 to $120');
    await expect(page.getByTestId('ads-price')).toHaveValue(/^From \$120 a day/);
    await page.getByTestId('ads-mark-posted').click();
    await page.getByTestId('ads-mark-posted-submit').click();
    await expect.poll(async () => (await sql`select a.needs_update, t.status from ad_postings a left join tasks t on t.related_id = a.id and t.task_type = 'ad_update'
      where a.vehicle_id = ${car} and a.channel = 'kijiji' and a.status = 'live'`).map((r) => `${String(r.needs_update)}/${String(r.status)}`).join(','), { timeout: 60_000 }).toBe('false/done');

    // ---------------------------------------------------------------- next week's social drafts: written, approved, posted by hand
    const today = new Date();
    const nextMonday = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() + ((8 - today.getUTCDay()) % 7 || 7)));
    const week = nextMonday.toISOString().slice(0, 10);
    await page.goto(`/admin/marketing/social?week=${week}`, { waitUntil: 'networkidle' });
    await page.getByTestId('ads-write-week').click();
    await page.waitForURL(/added=/, { timeout: 60_000 });
    const draft = page.getByTestId('ads-draft-owner_program').first();
    await expect(draft).toBeVisible({ timeout: 30_000 });
    await expect(page.getByTestId('ads-caption-owner_program-facebook_page').first()).toHaveValue(/utm_source=facebook_page/);
    await axe(page, 'social drafts');
    await draft.getByTestId('ads-approve-owner_program').click();
    await expect(draft.getByTestId('ads-posted-owner_program-instagram')).toBeVisible({ timeout: 30_000 });
    await draft.getByTestId('ads-posted-owner_program-instagram').click();
    await dialog(page).getByLabel('The post\'s address (https://...)').fill('https://www.instagram.com/p/test-ads/');
    await dialog(page).getByTestId('ads-posted-owner_program-instagram-submit').click();
    await expect.poll(async () => (await sql`select posted #>> '{instagram,how}' as how from social_drafts where slot_date = ${addDays(week, 1)} and kind = 'owner_program' and source = 'auto'`)[0]?.how, { timeout: 60_000 }).toBe('hand');

    // ---------------------------------------------------------------- the report and the Meta switch
    await page.goto('/admin/marketing/report', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('ads-report-channels')).toBeVisible();
    await axe(page, 'bookings by channel');
    await page.goto('/admin/settings/meta-publishing', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('meta-settings')).toContainText(/Off|Not ready|On/);
    await expect(page.getByTestId('meta-steps')).toContainText('instagram_content_publish');
    await axe(page, 'meta publishing');

    // ---------------------------------------------------------------- owner recruitment: nothing without consent
    await page.goto('/admin/marketing/recruit', { waitUntil: 'networkidle' });
    await page.getByTestId('rc-add').click();
    const name = `Sam Seller ${tag()}`;
    await dialog(page).getByLabel('The classified ad\'s address (https://...)').fill(`https://www.kijiji.ca/v-cars/toronto/civic/${tag()}`);
    await dialog(page).getByLabel('Name', { exact: true }).fill(name);
    await dialog(page).getByLabel('Phone (from the ad)').fill(`416-555-01${String(Math.floor(Math.random() * 90) + 10)}`);
    await dialog(page).getByLabel('Email (only if they published it or gave it to you)').fill(`seller.${tag()}@example.test`);
    await dialog(page).getByLabel('The car (for example 2021 Honda Civic)').fill('2021 Honda Civic');
    await page.getByTestId('rc-add-submit').click();
    await page.waitForURL(/\/admin\/marketing\/recruit\/[0-9a-f-]{36}$/, { timeout: 60_000 });
    await expect(page.getByTestId('rc-email-no')).toContainText('No consent yet');
    await expect(page.getByTestId('rc-send-after_call')).toBeDisabled();
    await expect(page.getByTestId('rc-send-text_after_call')).toBeDisabled();
    await axe(page, 'recruitment lead');
    const lead = page.url().split('/').pop()!;
    // a yes on the phone allows texts
    await page.getByTestId('rc-log-call').click();
    await dialog(page).getByLabel(/Their words/).fill('Yes, text me the details');
    await page.getByTestId('rc-log-call-submit').click();
    await expect(page.getByTestId('rc-text-ok')).toBeVisible({ timeout: 60_000 });
    await expect(page.getByTestId('rc-email-no')).toBeVisible();
    await page.getByTestId('rc-send-text_after_call').click();
    await page.getByTestId('rc-send-text_after_call-submit').click();
    await expect.poll(async () => (await sql`select o.body from recruit_messages m join phone_outbox o on o.id = m.phone_outbox_id where m.lead_id = ${lead}`)[0]?.body as string | undefined, { timeout: 60_000 })
      .toMatch(/CarmaCars owner program.*Reply STOP to opt out\.$/);
    const log = await sql`select basis, method from recruit_consents where lead_id = ${lead} order by created_at`;
    expect(log.map((r) => `${String(r.basis)}/${String(r.method)}`)).toEqual(['express/oral']);
    // do not contact: nothing may go any more
    await page.getByTestId('rc-dnc').click();
    await page.getByTestId('rc-dnc-submit').click();
    await expect.poll(async () => (await sql`select do_not_contact_at is not null as dnc from leads where id = ${lead}`)[0]?.dnc, { timeout: 60_000 }).toBe(true);

    expect(errors.filter((e) => !/favicon|Failed to load resource/i.test(e))).toEqual([]);
  } finally {
    await sql`update vehicles set retired_at = now(), retired_reason = 'ads e2e' where id = ${car}`.catch(() => undefined);
    await sql.end();
  }
});

function addDays(day: string, n: number): string { const d = new Date(`${day}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
