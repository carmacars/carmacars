import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Migration 0340 end to end, at 375 and 1440: a Sales rep brings in a car owner. On My sales, Owners you bring in: invite an
// owner (the lead is theirs), Start an application opens the Sales form (no terms, sourced by them), the owner they brought
// in asks for a commission (a percent, its base and how long), and the Admin sees it under Staff commissions, Owner requests,
// changes and approves it; the rep sees the Admin's terms. A second rep never sees the first rep's owners. Every page is
// checked with axe and for overflow and long dashes.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function check(page: Page, where: string, scope?: string) {
  await noOverflow(page);
  let axe = new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']);
  if (scope) axe = axe.include(scope);
  const r = await axe.analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(await page.locator('body').innerText(), `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va', name: string, va?: string) {
  const id = randomUUID(); const email = `r26s.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va!}, 0)`;
  return { id, email };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
const benign = (e: string) => /Failed to load resource|favicon|the server responded/.test(e);

test('Sales bring in owners: invite, start an application, ask for a commission; the Admin changes and approves it; reps see only their own', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const phone = test.info().project.name.startsWith('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
  const t = tag();
  const admin = await mkUser(sql, 'admin', 'Ada Admin');
  const rep = await mkUser(sql, 'va', 'Sam Seller', 'sales');
  const other = await mkUser(sql, 'va', 'Olly Other', 'sales');
  // an owner Sam brought in, who has applied (the invitation path is tested in the database suite)
  const ownerId = randomUUID();
  await sql`insert into owners (id, owner_type, legal_name, status, email, phone, recruited_by, recruited_at, recruited_via)
            values (${ownerId}, 'individual', ${`Nora Owner ${t}`}, 'lead', ${`r26s.nora.${t}@example.test`}, '4165550111', ${rep.id}, now(), 'invite')`;
  await sql`insert into owner_applications (owner_id, source, sourced_by) values (${ownerId}, 'web', ${rep.id})`;

  // the rep: My sales, Owners you bring in
  const rp = await ctx(browser, phone);
  const rErr = watch(rp);
  await signIn(rp, rep.email, '/staff');
  await rp.goto('/staff/my-sales', { waitUntil: 'networkidle' });
  const card = rp.getByTestId('sales-owners');
  await expect(card).toBeVisible({ timeout: 30_000 });
  await expect(card.getByTestId('so-count-applied')).toContainText('1');
  await check(rp, 'My sales, Owners you bring in', '[data-testid="sales-owners"]');

  // invite an owner: the "asked" box is required, then the lead is the rep's
  await card.getByTestId('so-invite-open').click();
  const inv = rp.getByTestId('so-invite-form');
  await inv.getByTestId('so-invite-name').fill(`Ivan Invitee ${t}`);
  await inv.getByTestId('so-invite-email').fill(`r26s.ivan.${t}@example.test`);
  await inv.getByTestId('so-invite-send').click();
  await expect(inv.getByText('Send it only to an owner who asked you for it.')).toBeVisible();
  await check(rp, 'Invite an owner', '.so-dialog[open]');
  await inv.getByTestId('so-invite-asked').check();
  await inv.getByTestId('so-invite-send').click();
  await expect(card.getByTestId('so-invite-done')).toContainText(`r26s.ivan.${t}@example.test`, { timeout: 30_000 });
  await expect(card.getByTestId('so-invite').first()).toContainText(`Ivan Invitee ${t}`);
  const [lead] = await sql`select (sourced_by = ${rep.id}) mine, followup_next_at from leads where email = ${`r26s.ivan.${t}@example.test`}`;
  expect([lead!.mine, lead!.followup_next_at]).toEqual([true, null]);
  await check(rp, 'My sales after an invitation', '[data-testid="sales-owners"]');

  // ask for a commission on Nora: a percent of the company's share, for 12 months
  await card.getByTestId(`so-ask-${ownerId}`).click();
  const ask = rp.getByTestId('so-ask-form');
  await ask.getByTestId('so-ask-percent').check();
  await ask.getByTestId('so-ask-rate').fill('10');
  await expect(ask.getByTestId('so-ask-base')).toHaveValue('company_share');
  await ask.getByTestId('so-ask-send').click();
  await expect(ask.getByTestId('so-ask-error')).toContainText('how long');
  await ask.getByTestId('so-ask-months').fill('12');
  await check(rp, 'Ask for a commission', '.so-dialog[open]');
  await ask.getByTestId('so-ask-send').click();
  const row = card.getByTestId(`so-owner-${ownerId}`);
  await expect(row.getByTestId('so-request')).toContainText('Asked: 10% of the company\'s share for 12 months. Waiting for an Admin.', { timeout: 30_000 });

  // Start an application: the Sales form, without terms, sourced by the rep
  await card.getByTestId('so-start').click();
  await rp.waitForURL('**/staff/owners/add-car');
  await expect(rp.getByTestId('addcar')).toBeVisible({ timeout: 30_000 });
  await expect(rp.getByTestId('addcar-sourced-you')).toBeVisible();
  await expect(rp.getByTestId('addcar-terms-ins')).toHaveCount(0);
  await expect(rp.getByTestId('addcar-search')).toHaveCount(0);
  await check(rp, 'Start an application (Sales)');

  // a second rep sees none of it
  const op = await ctx(browser, phone);
  const oErr = watch(op);
  await signIn(op, other.email, '/staff');
  await op.goto('/staff/my-sales', { waitUntil: 'networkidle' });
  await expect(op.getByTestId('sales-owners')).toBeVisible({ timeout: 30_000 });
  await expect(op.getByTestId('so-empty')).toBeVisible();
  await expect(op.getByText(`Nora Owner ${t}`)).toHaveCount(0);
  // the whole owner pipeline is not for Sales (0342): the old page goes to My sales, and Buyer leads lists no owner lead
  await op.goto('/staff/owner-pipeline', { waitUntil: 'networkidle' });
  await op.waitForURL('**/staff/my-sales**');
  await op.goto('/staff/leads', { waitUntil: 'networkidle' });
  await expect(op.getByTestId('leads-owners-moved')).toBeVisible({ timeout: 30_000 });
  await expect(op.getByText(`Ivan Invitee ${t}`)).toHaveCount(0);
  await check(op, 'Buyer leads (Sales)');

  // the Admin: Owner requests, change and approve (a flat CA$250 instead)
  const ap = await ctx(browser, phone);
  const aErr = watch(ap);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/money/commissions?tab=owners', { waitUntil: 'networkidle' });
  const list = ap.getByTestId('owner-requests');
  await expect(list).toContainText(`Nora Owner ${t}`, { timeout: 30_000 });
  await check(ap, 'Owner requests');
  const [rq] = await sql`select id from owner_recruit_requests where owner_id = ${ownerId}`;
  await ap.getByTestId(`orq-change-${rq!.id}`).click();
  const ch = ap.getByTestId(`orq-change-${rq!.id}-form`);
  await ch.getByLabel('Flat or percent').selectOption('flat');
  await ch.getByLabel(/^Flat amount/).fill('250');
  await ch.getByLabel(/^Note/).fill('Flat for a first owner');
  await check(ap, 'Change and approve', 'dialog[open]');
  await ap.getByTestId(`orq-change-${rq!.id}-submit`).click();
  await expect(list).toContainText('Approved, changed', { timeout: 30_000 });
  // the list may already hold another run's "Approved, changed": wait for this request's row itself
  await expect.poll(async () => { const [done] = await sql`select status, a_kind, a_amount_cents, changed from owner_recruit_requests where id = ${rq!.id}`;
    return [done!.status, done!.a_kind, Number(done!.a_amount_cents), done!.changed]; }, { timeout: 30_000 }).toEqual(['approved', 'flat', 25000, true]);

  // the rep sees the Admin's terms
  await rp.goto('/staff/my-sales', { waitUntil: 'networkidle' });
  await expect(rp.getByTestId(`so-owner-${ownerId}`).getByTestId('so-request')).toContainText('Approved: CA$250.00 at the first paid rental', { timeout: 30_000 });
  await expect(rp.getByTestId(`so-ask-${ownerId}`)).toHaveCount(0);
  await check(rp, 'My sales, approved', '[data-testid="sales-owners"]');

  expect([...rErr, ...oErr, ...aErr].filter((e) => !benign(e))).toEqual([]);
  await sql.end();
});
