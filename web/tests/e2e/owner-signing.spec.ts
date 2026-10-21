import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Owner signing that never crashes (migration 0075), end to end at 375 and 1440:
//   an individual owner, a corporation owner whose car staff added for them (0067, "No invoice" chosen), and an owner
//   with custom terms press "Check and sign" on /owner, read the documents at once (no PDF is made on the page), wait a
//   few seconds while each document is prepared in its own request, sign once, and see the success screen at once; the
//   signatures are recorded against the SHA-256 of the PDF opened, the signed copies are made by background jobs, and
//   signing makes no first and last month invoice (Admin > Today asks for the decision). A failed preparation shows a
//   friendly message with Try again, never a crashed page. Every page is checked with axe, for overflow and the copy rules.
// Fictional people only; the local stack only writes the emails' events.
const SHOTS = 'test-results/owner-signing';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled'], [/\d{6,} Canada Inc/, 'numbered company']];
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const vin = () => `1G1ZD5ST${randomBytes(5).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
const plate = () => `SG${randomBytes(2).toString('hex').toUpperCase()}`;
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png`, fullPage: true });

async function mkUser(sql: Sql, kind: 'admin' | 'plain', name: string) {
  const id = randomUUID(); const email = `${kind}.sg.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email, name };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept());
  return p;
}
const car = () => ({ vin: vin(), plate: plate(), year: 2022, make: 'Chevrolet', model: 'Malibu', colour: 'Grey', odometer_km: 41000, management_mode: 'managed', onboarding_method: 'transfer',
  current_insurer: 'Aviva', title_status: 'owned_outright', title_brand_clear: true });
const ownerFields = (who: { email: string; name: string }, corp: boolean) => {
  const [first, ...rest] = who.name.split(' ');
  return { owner_type: corp ? 'corporation' : 'individual', legal_name: corp ? `${rest.join(' ')} Holdings Ltd.` : who.name, ...(corp ? { corporation_name: `${rest.join(' ')} Holdings Ltd.`, signing_officer_name: who.name, signing_officer_title: 'President' } : {}),
    first_name: first, last_name: rest.join(' '), email: who.email, phone: '+16475550144', address_line1: '40 King Street West', city: 'Toronto', province: 'ON', postal_code: 'M5H 1A1',
    licence_number: `S${randomBytes(2).toString('hex').toUpperCase()}4-56789-01234`, date_of_birth: '1988-04-04' };
};
async function application(sql: Sql, who: { id: string; email: string; name: string }, corp = false) {
  const r = await sql`select public.server_submit_owner_application(${sql.json({ source: 'web', owner: ownerFields(who, corp), vehicles: [car()] })}, ${who.id}) r`;
  const ownerId = (r[0]!.r as { owner_id: string }).owner_id;
  const [a] = await sql`select id from owner_applications where owner_id = ${ownerId} order by created_at desc limit 1`;
  return { ownerId, appId: a!.id as string };
}
const upfront = async (sql: Sql, ownerId: string) => (await sql`select count(*)::int n from owner_invoices where owner_id = ${ownerId} and kind = 'upfront'`)[0]!.n as number;

/** The owner presses "Check and sign" on /owner and signs everything once; returns the timings. */
async function signFromHome(op: Page, name: string, where: string) {
  const errors = watch(op);
  await op.goto('/owner', { waitUntil: 'networkidle' });
  await op.getByRole('link', { name: 'Check and sign' }).first().click();
  const t0 = Date.now();
  await op.waitForURL(/\/owner\/sign$/, { timeout: 20_000 });
  // the documents are readable at once, from their text
  await expect(op.getByTestId('sign-progress')).toBeVisible();
  await expect(op.locator('.sg-docs summary').first()).toBeVisible();
  const shown = Date.now() - t0;
  // the sign form appears once each document is prepared (one request each)
  await expect(op.getByTestId('package-sign')).toBeVisible({ timeout: 45_000 });
  const ready = Date.now() - t0;
  await check(op, `${where} sign page`);
  await shot(op, `${where}-sign`);
  if (await op.getByTestId('package-tick-all').isVisible()) await op.getByTestId('package-tick-all').check();
  if (await op.getByTestId('package-initials').isVisible()) await op.getByTestId('package-initials').fill(name.split(' ').map((w) => w[0]).join('').slice(0, 3));
  await expect(op.getByTestId('signature-adopted')).toContainText(name);
  const t1 = Date.now();
  await op.getByTestId('package-sign').click();
  await op.waitForURL(/\/owner\?signed=1/, { timeout: 30_000 });
  const submitted = Date.now() - t1;
  await expect(op.getByTestId('owner-signed-banner')).toContainText('your signature is recorded');
  await check(op, `${where} signed`);
  expect(errors.filter((e) => !/favicon|Failed to load resource.*(404|401)/.test(e))).toEqual([]);
  console.log(`${where} (${test.info().project.name}): text shown in ${shown} ms, sign form ready in ${ready} ms, submit to success screen in ${submitted} ms`);
  return { shown, ready, submitted };
}

/** Signatures recorded against the PDF opened; the copies made by the jobs; no first and last month invoice. */
async function expectSigned(sql: Sql, ownerId: string, role: string) {
  const recs = await sql`select a.kind, d.sha256 doc_sha, d.content_key is not null keyed,
      (select string_agg(r.signer_role || ':' || (r.document_sha256 = d.sha256), ',' order by r.signer_role) from signature_records r where r.signature_request_id = a.signature_request_id) recs
    from owner_agreements a join signature_requests q on q.id = a.signature_request_id join documents d on d.id = q.document_id
   where a.owner_id = ${ownerId} and a.kind in ('enrollment', 'title_holding') order by a.kind`;
  expect(recs.map((r) => `${r.kind}/${r.keyed}/${r.recs}`)).toEqual([`enrollment/true/carmacars:true,${role}:true`, `title_holding/true/carmacars:true,${role}:true`]);
  await expect.poll(async () => (await sql`select count(*)::int n from owner_agreements a join signature_requests q on q.id = a.signature_request_id
      where a.owner_id = ${ownerId} and a.kind in ('enrollment', 'title_holding') and q.signed_document_id is not null`)[0]!.n, { timeout: 60_000, message: 'signed copies made by the jobs' }).toBe(2);
  // every signed copy of the package (the agreements and Form A or B when the car needs it) was made by a job
  await expect.poll(async () => (await sql`select string_agg(distinct status, ',') s from pdf_jobs where owner_id = ${ownerId}`)[0]!.s, { timeout: 60_000 }).toBe('done');
  expect((await sql`select count(*)::int n from pdf_jobs where owner_id = ${ownerId} and kind = 'owner_signed_copy'`)[0]!.n).toBe(2);
  expect(await upfront(sql, ownerId), 'signing makes no first and last month invoice').toBe(0);
}

test.describe.configure({ mode: 'serial' });

test('an individual owner: Check and sign, documents shown at once, prepared in the background, signed; no invoice, a to-do for the Admin', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Sg Admin');
  const owner = await mkUser(sql, 'plain', `Iris Individual${tag()}`);
  const app = await application(sql, owner);
  await sql`select public.door(${admin.id}, null, 'ops_do', 'application_approve', ${sql.json({ id: app.appId })})`;
  expect(await upfront(sql, app.ownerId), 'approve without a choice makes no invoice').toBe(0);
  const op = await ctx(browser);
  await signIn(op, owner.email, '/owner');
  await signFromHome(op, owner.name, 'individual');
  await expectSigned(sql, app.ownerId, 'owner_individual');
  // a second visit opens nothing again and renders nothing (the same content is open... and now signed)
  await op.goto('/owner/sign', { waitUntil: 'networkidle' });
  await expect(op.locator('h1')).toHaveText('Nothing to sign here');
  await check(op, 'individual after signing');
  // the Admin's to-do and the choice on the Terms tab
  const [t] = await sql`select title from tasks where task_type = 'first_last_decide' and owner_id = ${app.ownerId} and status = 'open'`;
  expect(t?.title).toMatch(/^Decide the first and last month invoice for 2022 Chevrolet Malibu/);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/owners/${app.ownerId}?tab=terms`, { waitUntil: 'networkidle' });
  const fl = page.getByTestId('first-last-choice').first();
  await expect(fl.getByTestId('first-last-undecided')).toBeVisible();
  await check(page, 'terms tab, first and last undecided');
  await fl.getByTestId('first-last-draft').check();
  await expect(fl.getByTestId('first-last-amount')).toHaveValue('900.00');
  await fl.getByTestId('first-last-amount').fill('850.25');
  await fl.getByTestId('first-last-save').click();
  await expect.poll(async () => (await sql`select status || ':' || fees_cents s from owner_invoices where owner_id = ${app.ownerId} and kind = 'upfront'`)[0]?.s, { timeout: 20_000 }).toBe('draft:85025');
  expect((await sql`select status from tasks where task_type = 'first_last_decide' and owner_id = ${app.ownerId}`)[0]!.status).toBe('done');
  await shot(page, 'terms-first-last');
  await page.context().close();
  await op.context().close();
  await sql.end();
});

test('a corporation owner whose car staff added (0067, No invoice chosen) signs for the corporation', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Sg Admin Two');
  const officer = await mkUser(sql, 'plain', `Cora Corporate${tag()}`);
  const added = (await sql`select public.door(${admin.id}, null, 'ops_do', 'staff_add_owner_car', ${sql.json({ owner: ownerFields(officer, true), vehicle: car(), signing: 'email',
    plan: { terms: { insurance_fee_cents: 41000 }, invoices: [{ type: 'first_last', action: 'none' }] } })}) r`)[0]!.r as { owner_id: string; vehicle_id: string; approved: boolean };
  expect(added.approved).toBe(true);
  // the officer's sign-in, linked as the set-up email would (0067)
  await sql`update owners set user_id = ${officer.id} where id = ${added.owner_id}`;
  await sql`insert into user_roles (user_id, role) values (${officer.id}, 'owner') on conflict do nothing`;
  expect((await sql`select first_last_choice from vehicle_onboardings where vehicle_id = ${added.vehicle_id}`)[0]!.first_last_choice).toBe('none');
  const op = await ctx(browser);
  await signIn(op, officer.email, '/owner');
  await op.goto('/owner/sign', { waitUntil: 'networkidle' });
  await expect(op.locator('body')).toContainText(`${officer.name}, for`, { timeout: 20_000 });
  await signFromHome(op, officer.name, 'corporation');
  await expectSigned(sql, added.owner_id, 'owner_corporation');
  // No invoice: nothing to wait for; the car moved past "upfront paid", and there is no to-do
  expect((await sql`select status from vehicle_onboardings where vehicle_id = ${added.vehicle_id}`)[0]!.status).toBe('upfront_paid');
  expect((await sql`select count(*)::int n from tasks where task_type = 'first_last_decide' and vehicle_id = ${added.vehicle_id} and status = 'open'`)[0]!.n).toBe(0);
  await op.context().close();
  await sql.end();
});

test('an owner with custom terms sees and signs the agreed numbers; a failed preparation shows Try again, never a crash', async ({ browser }) => {
  const sql = db();
  const admin = await mkUser(sql, 'admin', 'Sg Admin Three');
  const owner = await mkUser(sql, 'plain', `Carl Custom${tag()}`);
  const app = await application(sql, owner);
  await sql`select public.door(${admin.id}, null, 'ops_do', 'owner_terms_save', ${sql.json({ owner_id: app.ownerId, insurance_fee_cents: 37750, revenue_share_bps: 2750, first_last_cents: 70000, note: 'Agreed by phone' })})`;
  await sql`select public.door(${admin.id}, null, 'ops_do', 'application_approve', ${sql.json({ id: app.appId })})`;
  const op = await ctx(browser);
  await signIn(op, owner.email, '/owner');
  // the first preparation fails: a friendly message with Try again; the page itself stays whole
  let fail = true;
  await op.route('**/api/sign/prepare', (r) => (fail ? r.fulfill({ status: 500, contentType: 'application/json', body: '{"ok":false,"message":"We could not prepare this document. Try again in a moment."}' }) : r.continue()));
  await op.goto('/owner/sign', { waitUntil: 'domcontentloaded' });
  await expect(op.getByTestId('prepare-docs-error')).toBeVisible({ timeout: 20_000 });
  await expect(op.getByTestId('prepare-docs-error')).toContainText('nothing was signed');
  await expect(op.locator('.sg-docs summary').first()).toBeVisible();
  await expect(op.locator('body')).toContainText('$377.50');
  await check(op, 'custom terms, preparation failed');
  await shot(op, 'prepare-failed');
  fail = false;
  await op.getByTestId('prepare-docs-retry').click();
  await expect(op.getByTestId('package-sign')).toBeVisible({ timeout: 45_000 });
  await op.unroute('**/api/sign/prepare');
  await signFromHome(op, owner.name, 'custom terms');
  await expectSigned(sql, app.ownerId, 'owner_individual');
  const [s] = await sql`select s.insurance_fee_cents::int ins, s.revenue_share_bps share, s.first_last_cents::int fl from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where v.owner_id = ${app.ownerId} and s.superseded_by is null`;
  expect(`${s!.ins}/${s!.share}/${s!.fl}`).toBe('37750/2750/70000');
  await op.context().close();
  await sql.end();
});
